using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// The recording thread drains WinMM buffers and handles transport commands.
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
    [DllImport("winmm.dll")] static extern uint waveInOpen(out IntPtr handle, uint device, ref Format format, IntPtr signal, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInStop(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInClose(IntPtr handle);
    [DllImport("winmm.dll", CharSet=CharSet.Unicode)] static extern uint mciSendString(string command, StringBuilder result, int size, IntPtr window);
    static readonly uint headerSize = (uint)Marshal.SizeOf(typeof(Header));
    const int bufferSize = 1600; // 50 ms at 16 kHz, mono, 16-bit PCM.
    const uint headerDone = 1;
    const uint callbackEvent = 0x50000;
    static IntPtr device;
    static FileStream file;
    static long bytes;
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
    static void Report(string value) {
        Console.WriteLine(value); Console.Out.Flush();
    }
    static int AudioLevel(byte[] chunk, int size) {
        double sum = 0;
        for (int offset = 0; offset + 1 < size; offset += 2) {
            short sample = (short)(chunk[offset] | chunk[offset + 1] << 8);
            sum += (double)sample * sample;
        }
        return Math.Min(100, (int)Math.Round(300 * Math.Sqrt(sum / (size / 2)) / 32768));
    }
    static void Drain(IntPtr[] headers, int count, ref int next, byte[] chunk, bool queueAgain) {
        for (int visited = 0; visited < count; visited++) {
            IntPtr pointer = headers[next];
            var header = (Header)Marshal.PtrToStructure(pointer, typeof(Header));
            if ((header.flags & headerDone) == 0) break;
            int length = (int)header.recorded;
            if (length >= 2) {
                Marshal.Copy(header.data, chunk, 0, length);
                file.Write(chunk, 0, length); bytes += length;
            }
            if (queueAgain) Check(waveInAddBuffer(device, pointer, headerSize));
            next = (next + 1) % count;
            if (queueAgain && length >= 2) Report("level " + AudioLevel(chunk, length));
        }
    }
    static void Record(string target) {
        var format = new Format {tag=1, channels=1, rate=16000, bytesPerSecond=32000, align=2, bits=16};
        IntPtr[] headers = new IntPtr[8], buffers = new IntPtr[8];
        var chunk = new byte[bufferSize];
        int prepared = 0, next = 0;
        using(var signal = new AutoResetEvent(false))
        using(file = new FileStream(target, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read)) {
            WriteHeader();
            Check(waveInOpen(out device, 0xffffffff, ref format, signal.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, callbackEvent));
            try {
                for(int i=0;i<headers.Length;i++) {
                    buffers[i]=Marshal.AllocHGlobal(bufferSize);
                    headers[i]=Marshal.AllocHGlobal((int)headerSize);
                    Marshal.StructureToPtr(new Header {data=buffers[i],length=bufferSize},headers[i],false);
                    Check(waveInPrepareHeader(device, headers[i], headerSize));
                    prepared++;
                    Check(waveInAddBuffer(device, headers[i], headerSize));
                }
                Check(waveInStart(device)); Report("recording");
                var command = Task.Factory.StartNew(() => Console.ReadLine());
                DateTime deadline=DateTime.UtcNow.AddHours(5);
                DateTime nextFlush = DateTime.UtcNow.AddMilliseconds(250);
                bool paused = false;
                while (DateTime.UtcNow < deadline) {
                    Drain(headers, prepared, ref next, chunk, true);
                    if (command.IsCompleted) {
                        string value = command.GetAwaiter().GetResult();
                        if (value == null || value == "stop") break;
                        if (value == "pause" && !paused) {
                            Check(waveInStop(device));
                            Drain(headers, prepared, ref next, chunk, true);
                            WriteHeader(); paused = true; Report("paused");
                        }
                        if (value == "resume" && paused) {
                            Check(waveInStart(device)); paused = false; Report("resumed");
                        }
                        command = Task.Factory.StartNew(() => Console.ReadLine());
                    }
                    if (!paused && DateTime.UtcNow >= nextFlush) {
                        WriteHeader(); nextFlush = DateTime.UtcNow.AddMilliseconds(250);
                    }
                    signal.WaitOne(20);
                }
            } finally {
                try {
                    Check(waveInReset(device));
                    if (prepared == headers.Length) Drain(headers, prepared, ref next, chunk, false);
                    WriteHeader();
                } finally {
                    for(int i=0;i<headers.Length;i++) {
                        if(i<prepared) waveInUnprepareHeader(device,headers[i],headerSize);
                        if(headers[i]!=IntPtr.Zero) Marshal.FreeHGlobal(headers[i]);
                        if(buffers[i]!=IntPtr.Zero) Marshal.FreeHGlobal(buffers[i]);
                    }
                    waveInClose(device);
                }
            }
        }
        Report("stopped");
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
