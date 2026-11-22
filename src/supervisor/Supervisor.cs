using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Collections.Generic;

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
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(IntPtr file,uint code,byte[] input,uint length,IntPtr output,uint outputSize,out uint returned,IntPtr overlapped);
    static void Check(bool value) { if(!value)throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static string Quote(string value) { return "\""+value.Replace("\"","\\\"")+"\""; }
    internal static void Log(string root, string message) {
        File.AppendAllText(Path.Combine(root, "logs", "supervisor.log"), DateTime.UtcNow.ToString("o")+" "+message+Environment.NewLine);
    }
    internal static void MakeJunction(string name, string target) {
        Directory.CreateDirectory(name);
        byte[] substitute = Encoding.Unicode.GetBytes(@"\??\" + Path.GetFullPath(target));
        byte[] display = Encoding.Unicode.GetBytes(Path.GetFullPath(target));
        var attributes = new SecurityAttributes();
        attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
        IntPtr handle = CreateFile(name, 0x40000000, 7, ref attributes, 3, 0x02200000, IntPtr.Zero);
        Check(handle != new IntPtr(-1));
        try {
            using (var data = new MemoryStream())
            using (var writer = new BinaryWriter(data)) {
                writer.Write(0xa0000003u);
                writer.Write((ushort)(substitute.Length + display.Length + 12));
                writer.Write((ushort)0);
                writer.Write((ushort)0); writer.Write((ushort)substitute.Length);
                writer.Write((ushort)(substitute.Length + 2)); writer.Write((ushort)display.Length);
                writer.Write(substitute); writer.Write((ushort)0);
                writer.Write(display); writer.Write((ushort)0);
                byte[] buffer = data.ToArray();
                uint returned;
                Check(DeviceIoControl(handle, 0x000900a4, buffer, (uint)buffer.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero));
            }
        } finally { CloseHandle(handle); }
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
            var recovery = new Recovery(root);
            recovery.Prepare();
            string ipc = recovery.Setting("ipc"), logs = recovery.Setting("logs");
            job=CreateJobObject(IntPtr.Zero,null);Check(job!=IntPtr.Zero);
            var limits=new ExtendedLimit();limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE; no breakaway flags.
            Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(limits)));
            var sa=new SecurityAttributes();sa.Length=Marshal.SizeOf(sa);sa.Inherit=true;
            output=CreateFile(Path.Combine(logs,"runtime.stdout.log"),0x40000000,3,ref sa,2,0x80,IntPtr.Zero);
            error=CreateFile(Path.Combine(logs,"runtime.stderr.log"),0x40000000,3,ref sa,2,0x80,IntPtr.Zero);
            Check(output!=new IntPtr(-1)&&error!=new IntPtr(-1));
            var startup=new StartupInfo();startup.Size=Marshal.SizeOf(startup);startup.Flags=0x101;startup.ShowWindow=0;
            startup.Output=output;startup.Error=error;
            Environment.SetEnvironmentVariable("LOOM_JOB_SUPERVISOR_PID",Process.GetCurrentProcess().Id.ToString());
            Environment.SetEnvironmentVariable("LOOM_RUNTIME_EPOCH",Guid.NewGuid().ToString("D"));
            bool gui = Object.Equals(recovery.Config["gui"], true);
            string engine = recovery.Setting("engineExecutable");
            string script = Path.Combine(root,"src","runtime","direct-bootstrap.st");
            string arguments = Quote(engine)+(gui?" --interactive ":" ")+Quote(recovery.WorkingImage)+" st "+Quote(script);
            Check(CreateProcess(engine,new StringBuilder(arguments),IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,root,ref startup,out child));
            Check(AssignProcessToJobObject(job,child.Process));
            recovery.Write(Path.Combine(ipc,"supervisor.json"),new {pid=Process.GetCurrentProcess().Id,workerPid=child.ProcessId,killOnJobClose=true});
            string statusFile = Path.Combine(ipc,"runtime-status.json");
            recovery.Write(statusFile,new {status="starting",pid=child.ProcessId,enginePid=child.ProcessId,
                supervisorPid=Process.GetCurrentProcess().Id,root,gui,image=recovery.CommittedImage});
            string pulse = Path.Combine(ipc,"runtime-heartbeat.txt");
            if(File.Exists(pulse))File.Delete(pulse);
            Check(ResumeThread(child.Thread)!=0xFFFFFFFF);
            DateTime started = DateTime.UtcNow;
            while(WaitForSingleObject(child.Process,50)==258) {
                try {
                    recovery.SealReadyCheckpoints();
                    DateTime lastPulse = File.Exists(pulse) ? File.GetLastWriteTimeUtc(pulse) : started;
                    if(!recovery.HasPendingCheckpoint() && (DateTime.UtcNow-lastPulse).TotalSeconds > (File.Exists(pulse) ? 15 : 45)) {
                        var status = recovery.Read(statusFile);
                        status["status"]="failed"; status["error"]="GT heartbeat stopped; closing its supervised job";
                        recovery.Write(statusFile,status);
                        Log(root,(string)status["error"]);
                        return 1;
                    }
                } catch(IOException) { }
            }
            uint exit;GetExitCodeProcess(child.Process,out exit);
            var stopped = recovery.Read(statusFile);
            if (!Object.Equals(stopped["status"], "stopped") && !Object.Equals(stopped["status"], "failed")) {
                stopped["status"] = "failed"; stopped["error"] = "GT exited unexpectedly (" + exit + ")";
                recovery.Write(statusFile, stopped);
                return 1;
            }
            return (int)exit;
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
