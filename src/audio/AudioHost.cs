using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Streaming WinMM capture. Only a few seconds of samples are held in memory.
class AudioHost {
    [StructLayout(LayoutKind.Sequential)] struct Format {
        public ushort tag, channels;
        public uint rate, bytesPerSecond;
        public ushort align, bits, extra;
    }
    [StructLayout(LayoutKind.Sequential)] struct Header {
        public IntPtr data;
        public uint length, recorded;
        public IntPtr user;
        public uint flags, loops;
        public IntPtr next, reserved;
    }
    delegate void WaveCallback(IntPtr handle, uint message, IntPtr instance, IntPtr header, IntPtr unused);
    [DllImport("winmm.dll")] static extern uint waveInOpen(out IntPtr handle, uint device, ref Format format, WaveCallback callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInStop(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInClose(IntPtr handle);
    [DllImport("winmm.dll", CharSet=CharSet.Unicode)] static extern uint mciSendString(string command, StringBuilder result, int size, IntPtr window);
    static readonly uint headerSize = (uint)Marshal.SizeOf(typeof(Header));
    static readonly object sync = new object();
    static IntPtr device;
    static FileStream file;
    static bool stopping;
    static long bytes;
    static Exception callbackError;
    static void Check(uint code) { if (code != 0) throw new Exception("Windows audio error " + code); }
    static void WriteHeader() {
        long position = file.Position;
        file.Position = 0;
        var writer = new BinaryWriter(file, Encoding.ASCII, true);
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write((uint)(bytes+36));
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((ushort)1); writer.Write((ushort)1); writer.Write(16000); writer.Write(32000);
        writer.Write((ushort)2); writer.Write((ushort)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write((uint)bytes);
        file.Position = Math.Max(44, position); file.Flush(true);
    }
    static void Receive(IntPtr handle, uint message, IntPtr instance, IntPtr pointer, IntPtr unused) {
        if (message != 0x3c0) return;
        lock(sync) {
            try {
                var header = (Header)Marshal.PtrToStructure(pointer, typeof(Header));
                if(header.recorded > 0) {
                    byte[] chunk = new byte[header.recorded];
                    Marshal.Copy(header.data, chunk, 0, chunk.Length);
                    file.Write(chunk, 0, chunk.Length); bytes += chunk.Length; WriteHeader();
                }
                if (!stopping) Check(waveInAddBuffer(handle, pointer, headerSize));
            } catch(Exception error) { callbackError = error; stopping = true; }
        }
    }
    static void Record(string target) {
        WaveCallback callback = Receive;
        var format = new Format {tag=1, channels=1, rate=16000, bytesPerSecond=32000, align=2, bits=16};
        IntPtr[] headers = new IntPtr[8], buffers = new IntPtr[8];
        using(file = new FileStream(target, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read)) {
            WriteHeader();
            Check(waveInOpen(out device, 0xffffffff, ref format, callback, IntPtr.Zero, 0x30000));
            try {
                for(int i=0;i<headers.Length;i++) {
                    buffers[i]=Marshal.AllocHGlobal(16000);
                    headers[i]=Marshal.AllocHGlobal((int)headerSize);
                    Marshal.StructureToPtr(new Header {data=buffers[i],length=16000},headers[i],false);
                    Check(waveInPrepareHeader(device, headers[i], headerSize));
                    Check(waveInAddBuffer(device, headers[i], headerSize));
                }
                Check(waveInStart(device)); Console.WriteLine("recording"); Console.Out.Flush();
                Task<string> command = Task.Factory.StartNew(()=>Console.ReadLine());
                DateTime deadline=DateTime.UtcNow.AddHours(5);
                while(!command.IsCompleted && !stopping && DateTime.UtcNow < deadline) Thread.Sleep(50);
            } finally {
                stopping=true;
                waveInStop(device); waveInReset(device);
                for(int i=0;i<headers.Length;i++) if(headers[i]!=IntPtr.Zero) {
                    waveInUnprepareHeader(device,headers[i],headerSize);
                    Marshal.FreeHGlobal(headers[i]); Marshal.FreeHGlobal(buffers[i]);
                }
                waveInClose(device); GC.KeepAlive(callback);
                lock(sync) WriteHeader();
            }
        }
        if(callbackError!=null) throw callbackError;
        Console.WriteLine("stopped");
    }
    static void Play(string target) {
        if(target.Contains("\"")) throw new Exception("Invalid audio path");
        Check(mciSendString("open \""+target+"\" type waveaudio alias clip",null,0,IntPtr.Zero));
        try {
            Check(mciSendString("play clip",null,0,IntPtr.Zero)); Console.WriteLine("playing"); Console.Out.Flush();
            var command=Task.Factory.StartNew(()=>Console.ReadLine());
            while(!command.IsCompleted) {
                var mode=new StringBuilder(64); Check(mciSendString("status clip mode",mode,64,IntPtr.Zero));
                if(mode.ToString()!="playing") break;
                Thread.Sleep(100);
            }
        } finally { mciSendString("close clip",null,0,IntPtr.Zero); }
    }
    [STAThread] static int Main(string[] args) {
        Console.OutputEncoding=new UTF8Encoding(false);
        try {
            if(args.Length==1 && args[0]=="pick") {
                using(var picker=new OpenFileDialog {Title="选择音频", Filter="音频|*.wav;*.mp3;*.m4a;*.flac;*.ogg;*.opus;*.aac;*.wma|所有文件|*.*"})
                    if(picker.ShowDialog()==DialogResult.OK) Console.WriteLine(picker.FileName);
            } else if(args.Length==2 && args[0]=="record") Record(args[1]);
            else if(args.Length==2 && args[0]=="play") Play(args[1]);
            else throw new Exception("Expected record/play <file> or pick");
            return 0;
        } catch(Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
}
