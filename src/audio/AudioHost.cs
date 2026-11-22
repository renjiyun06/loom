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
    [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr handle, uint device, ref Format format, IntPtr signal, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr handle);
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
    static long ReadWave(BinaryReader reader, out Format format) {
        var stream = reader.BaseStream;
        format = new Format();
        if (new string(reader.ReadChars(4)) != "RIFF") throw new InvalidDataException("Expected RIFF audio");
        reader.ReadUInt32();
        if (new string(reader.ReadChars(4)) != "WAVE") throw new InvalidDataException("Expected WAV audio");
        while (stream.Length - stream.Position >= 8) {
            string kind = new string(reader.ReadChars(4));
            uint size = reader.ReadUInt32();
            long end = stream.Position + size;
            if (end > stream.Length) throw new InvalidDataException("WAV chunk is truncated");
            if (kind == "fmt " && size >= 16) {
                format.tag = reader.ReadUInt16(); format.channels = reader.ReadUInt16();
                format.rate = reader.ReadUInt32(); format.bytesPerSecond = reader.ReadUInt32();
                format.align = reader.ReadUInt16(); format.bits = reader.ReadUInt16();
            }
            if (kind == "data" && format.tag == 1 && format.align > 0 && size >= format.align)
                return size - size % format.align;
            stream.Position = end + (size & 1);
        }
        throw new InvalidDataException("Expected nonempty PCM data");
    }
    static void Play(string target) {
        using (var reader = new BinaryReader(File.OpenRead(target), Encoding.ASCII))
        using (var signal = new AutoResetEvent(false)) {
            Format format;
            long remaining = ReadWave(reader, out format);
            int size = Math.Max(format.align, (int)(format.bytesPerSecond / (20U * format.align)) * format.align);
            IntPtr handle;
            Check(waveOutOpen(out handle, 0xffffffff, ref format, signal.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, callbackEvent));
            var headers = new IntPtr[4];
            var buffers = new IntPtr[4];
            var queued = new bool[4];
            int prepared = 0;
            bool started = false;
            try {
                for (int index = 0; index < headers.Length; index++) {
                    buffers[index] = Marshal.AllocHGlobal(size);
                    headers[index] = Marshal.AllocHGlobal((int)headerSize);
                    Marshal.StructureToPtr(new Header {data=buffers[index],length=(uint)size},headers[index],false);
                    Check(waveOutPrepareHeader(handle, headers[index], headerSize));
                    prepared++;
                }
                var command = Task.Factory.StartNew(() => Console.ReadLine());
                int next = 0, pending = 0;
                do {
                    for (int visited = 0; visited < headers.Length; visited++) {
                        IntPtr pointer = headers[next];
                        var header = (Header)Marshal.PtrToStructure(pointer, typeof(Header));
                        if (queued[next] && (header.flags & headerDone) == 0) break;
                        if (queued[next]) { queued[next] = false; pending--; }
                        if (remaining > 0) {
                            int count = (int)Math.Min(size, remaining);
                            byte[] chunk = reader.ReadBytes(count);
                            if (chunk.Length != count) throw new EndOfStreamException();
                            Marshal.Copy(chunk, 0, buffers[next], count);
                            header.length = (uint)count;
                            Marshal.StructureToPtr(header, pointer, false);
                            Check(waveOutWrite(handle, pointer, headerSize));
                            queued[next] = true; pending++; remaining -= count;
                        }
                        next = (next + 1) % headers.Length;
                    }
                    if (!started) { Report("playing"); started = true; }
                    if (pending > 0 && !command.IsCompleted) signal.WaitOne(25);
                } while (pending > 0 && !command.IsCompleted);
            } finally {
                waveOutReset(handle);
                for (int index = 0; index < headers.Length; index++) {
                    if (index < prepared) waveOutUnprepareHeader(handle, headers[index], headerSize);
                    if (headers[index] != IntPtr.Zero) Marshal.FreeHGlobal(headers[index]);
                    if (buffers[index] != IntPtr.Zero) Marshal.FreeHGlobal(buffers[index]);
                }
                waveOutClose(handle);
            }
        }
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
