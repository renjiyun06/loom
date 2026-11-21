using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

// Owns the only Job handle. Closing or killing this process terminates its job.
public static class Supervisor {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
        public long PerProcess, PerJob; public uint Flags; public UIntPtr Min, Max;
        public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong A,B,C,D,E,F; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit {
        public BasicLimit Basic; public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
        public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public int Size; public string Reserved, Desktop, Title; public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags;
        public short ShowWindow, ReservedSize; public IntPtr Reserved2, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId,ThreadId; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimit limit,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr env,string cwd,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string file,uint access,uint share,ref SecurityAttributes sa,uint creation,uint flags,IntPtr template);
    static void Check(bool value) { if(!value)throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static string Quote(string value) { return "\""+value.Replace("\"","\\\"")+"\""; }
    static void WriteState(string file,string text) {
        string temp=file+".tmp";
        using(var stream=new FileStream(temp,FileMode.Create,FileAccess.Write,FileShare.None)) {
            byte[] bytes=Encoding.UTF8.GetBytes(text); stream.Write(bytes,0,bytes.Length);stream.Flush(true);
        }
        if(File.Exists(file))File.Replace(temp,file,null);else File.Move(temp,file);
    }
    static int Field(string json,string name) {
        var match=Regex.Match(json,"\""+name+"\"\\s*:\\s*(\\d+)");
        return match.Success?Int32.Parse(match.Groups[1].Value):0;
    }
    static string ReadShared(string file) {
        // Observing status must not prevent the bridge from atomically replacing it.
        using(var stream=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var reader=new StreamReader(stream))return reader.ReadToEnd();
    }
    [STAThread] public static int Main(string[] args) {
        if(args.Length!=1)return 2;
        string root=Path.GetFullPath(args[0]);
        IntPtr job=IntPtr.Zero,output=IntPtr.Zero,error=IntPtr.Zero;
        ProcessInfo child=new ProcessInfo();
        using(var mutex=new Mutex(false,"Local\\LoomCodexSupervisor-"+root.GetHashCode().ToString("X"))) {
          bool acquired=false;
          try {
            try {acquired=mutex.WaitOne(5000);}catch(AbandonedMutexException){acquired=true;}
            if(!acquired)throw new Exception("Another supervisor owns this environment");
            Directory.CreateDirectory(Path.Combine(root,"logs"));Directory.CreateDirectory(Path.Combine(root,"ipc"));
            job=CreateJobObject(IntPtr.Zero,null);Check(job!=IntPtr.Zero);
            var limits=new ExtendedLimit();limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE; no breakaway flags.
            Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(limits)));
            var sa=new SecurityAttributes();sa.Length=Marshal.SizeOf(sa);sa.Inherit=true;
            output=CreateFile(Path.Combine(root,"logs\\service.stdout.log"),0x40000000,3,ref sa,2,0x80,IntPtr.Zero);
            error=CreateFile(Path.Combine(root,"logs\\service.stderr.log"),0x40000000,3,ref sa,2,0x80,IntPtr.Zero);
            Check(output!=new IntPtr(-1)&&error!=new IntPtr(-1));
            var startup=new StartupInfo();startup.Size=Marshal.SizeOf(startup);startup.Flags=0x101;startup.ShowWindow=0;
            startup.Output=output;startup.Error=error;
            Environment.SetEnvironmentVariable("LOOM_JOB_SUPERVISOR_PID",Process.GetCurrentProcess().Id.ToString());
            string node=Path.Combine(root,"runtime\\node\\node.exe");
            string script=Path.Combine(root,"src\\bridge\\serve-codex.mjs");
            Check(CreateProcess(node,new StringBuilder(Quote(node)+" "+Quote(script)),IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,root,ref startup,out child));
            // Assignment happens before any Node or model code is allowed to execute.
            Check(AssignProcessToJobObject(job,child.Process));
            WriteState(Path.Combine(root,"ipc\\supervisor.json"),"{\"pid\":"+Process.GetCurrentProcess().Id+",\"workerPid\":"+child.ProcessId+",\"killOnJobClose\":true}");
            Check(ResumeThread(child.Thread)!=0xFFFFFFFF);
            Process engine=null,codex=null;
            string statusFile=Path.Combine(root,"ipc\\bridge-ready.json");
            while(WaitForSingleObject(child.Process,50)==258) {
                try {
                    if(!File.Exists(statusFile))continue;
                    string status=ReadShared(statusFile);
                    if(Field(status,"pid")!=(int)child.ProcessId)continue;
                    bool ready=Regex.IsMatch(status,"\"status\"\\s*:\\s*\"ready\"");
                    if(!ready)continue;
                    if(engine==null&&Field(status,"enginePid")>0)engine=Process.GetProcessById(Field(status,"enginePid"));
                    if(codex==null&&Field(status,"codexPid")>0)codex=Process.GetProcessById(Field(status,"codexPid"));
                    bool stopped=(engine!=null&&engine.HasExited)||(codex!=null&&codex.HasExited);
                    string pulse=Path.Combine(root,"ipc\\bridge-heartbeat.txt");
                    bool unresponsive=File.Exists(pulse)&&(DateTime.UtcNow-File.GetLastWriteTimeUtc(pulse)).TotalSeconds>15;
                    if(stopped||unresponsive) {
                        string failed=Regex.Replace(status,"\"status\"\\s*:\\s*\"ready\"","\"status\":\"failed\"");
                        WriteState(statusFile,failed);
                        File.AppendAllText(Path.Combine(root,"logs\\supervisor.log"),DateTime.UtcNow.ToString("o")+" Critical peer exited or bridge heartbeat stopped; closing job."+Environment.NewLine);
                        return 1;
                    }
                } catch(ArgumentException) { return 1; }
                  catch(IOException) { }
            }
            uint exit;GetExitCodeProcess(child.Process,out exit);return (int)exit;
          } catch(Exception ex) {
            try {File.AppendAllText(Path.Combine(root,"logs\\supervisor.log"),DateTime.UtcNow.ToString("o")+" "+ex+Environment.NewLine);}catch{}
            if(child.Process!=IntPtr.Zero)TerminateProcess(child.Process,1);return 1;
          } finally {
            if(job!=IntPtr.Zero)CloseHandle(job); // Kernel terminates the entire remaining subtree.
            if(child.Thread!=IntPtr.Zero)CloseHandle(child.Thread);
            if(child.Process!=IntPtr.Zero)CloseHandle(child.Process);
            if(output!=IntPtr.Zero&&output!=new IntPtr(-1))CloseHandle(output);
            if(error!=IntPtr.Zero&&error!=new IntPtr(-1))CloseHandle(error);
            if(acquired)mutex.ReleaseMutex();
          }
        }
    }
}
