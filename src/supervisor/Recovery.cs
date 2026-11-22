using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

internal sealed class Recovery {
    readonly string root, runtime, ipc, working, checkpoints, pointer;
    readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
    public Dictionary<string,object> Config { get; private set; }
    public string WorkingImage { get { return Path.Combine(working, "main.image"); } }
    public string CommittedImage { get; private set; }

    public Recovery(string root) {
        this.root = root;
        Config = Read(Path.Combine(root, "config", "runtime.json"));
        if (!Object.Equals(Config["schemaVersion"], 1)) throw new IOException("Unsupported runtime configuration");
        ipc = Setting("ipc");
        runtime = Path.Combine(root, "state", "runtime");
        working = Path.Combine(runtime, "working");
        checkpoints = Path.Combine(runtime, "checkpoints");
        pointer = Path.Combine(runtime, "current-image.json");
        foreach (string dir in new[] { runtime, working, checkpoints, ipc, Setting("logs"), Setting("temporary") })
            Directory.CreateDirectory(dir);
        foreach (string dir in new[] { "checkpoint-requests", "checkpoint-saved", "checkpoint-results" })
            Directory.CreateDirectory(Path.Combine(ipc, dir));
    }

    public string Setting(string key) {
        IDictionary<string,object> paths = (IDictionary<string,object>)Config["paths"];
        return WithinRoot((string)paths[key]);
    }

    string WithinRoot(string relative) {
        string value = Path.GetFullPath(Path.Combine(root, relative));
        if (!value.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Path outside Loom root");
        return value;
    }

    public Dictionary<string,object> Read(string file) {
        using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(stream))
            return serializer.Deserialize<Dictionary<string,object>>(reader.ReadToEnd());
    }

    public void Write(string file, object value) {
        string temporary = file + "." + Guid.NewGuid().ToString("D") + ".tmp";
        try {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                byte[] bytes = Encoding.UTF8.GetBytes(serializer.Serialize(value));
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            for (int retry = 0; ; retry++) {
                try {
                    if (File.Exists(file)) File.Replace(temporary, file, null);
                    else File.Move(temporary, file);
                    break;
                } catch (IOException) {
                    if (retry >= 20) throw;
                    System.Threading.Thread.Sleep(25);
                }
            }
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    static bool IsId(string value) {
        Guid id;
        return Guid.TryParseExact(value, "D", out id);
    }

    static void PlainDirectory(string name) {
        FileAttributes attributes = File.GetAttributes(name);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Loom recovery directory was redirected: " + name);
    }

    static string Hash(string file) {
        if ((File.GetAttributes(file) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("Loom recovery file was redirected: " + file);
        using (var sha = SHA256.Create())
        using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    static void Copy(string source, string target) {
        using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None)) {
            input.CopyTo(output);
            output.Flush(true);
        }
    }

    public void Prepare() {
        PlainDirectory(runtime);
        PlainDirectory(working);
        PlainDirectory(checkpoints);
        string seed = Setting("seedImage");
        Dictionary<string,object> existing = File.Exists(pointer) ? Read(pointer) : null;
        string image = Setting("image");
        if (existing != null) {
            string id = existing["id"] as string;
            if (!IsId(id)) throw new IOException("Invalid committed checkpoint identity");
            string folder = Path.Combine(checkpoints, id);
            PlainDirectory(folder);
            image = Path.Combine(folder, "resume.image");
            if (!String.Equals(image, WithinRoot((string)existing["image"]), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Invalid committed checkpoint path");
            if (Hash(image) != (string)existing["sha256"]) throw new IOException("Committed checkpoint image is damaged");
            string changesHash = Hash(Path.ChangeExtension(image, ".changes"));
            object expected;
            if (existing.TryGetValue("changesSha256", out expected) && expected != null && changesHash != (string)expected)
                throw new IOException("Committed checkpoint changes are damaged");
        } else if (!File.Exists(image)) {
            if (Directory.Exists(Path.GetDirectoryName(image))) PlainDirectory(Path.GetDirectoryName(image));
            Copy(seed, image);
            Copy(Path.ChangeExtension(seed, ".changes"), Path.ChangeExtension(image, ".changes"));
        }
        CommittedImage = image;
        Copy(image, WorkingImage);
        Copy(Path.ChangeExtension(image, ".changes"), Path.ChangeExtension(WorkingImage, ".changes"));
        foreach (string source in Directory.GetFiles(Path.GetDirectoryName(seed), "*.sources")) {
            string target = Path.Combine(working, Path.GetFileName(source));
            if (!File.Exists(target)) Copy(source, target);
        }
        var resources = Path.Combine(working, "gt-extra");
        if (!Directory.Exists(resources)) Supervisor.MakeJunction(resources, Path.Combine(Path.GetDirectoryName(seed), "gt-extra"));
        MoveSessionStore();
        ArchiveMailbox();
        foreach (string request in Directory.GetFiles(Path.Combine(ipc, "checkpoint-requests"), "*.json")) {
            string id = Path.GetFileNameWithoutExtension(request);
            string receipt = Receipt(id);
            if (!IsId(id) || File.Exists(receipt)) continue;
            if (existing != null && (string)existing["id"] == id) {
                var result = new Dictionary<string,object>(existing);
                result["ok"] = true;
                Write(receipt, result);
            } else Write(receipt, new { ok = false, id, error = "Interrupted before checkpoint commit; request was not replayed" });
        }
    }

    void MoveSessionStore() {
        string state = Path.Combine(root, "state");
        string previous = Path.Combine(state, "bridge");
        string current = Path.Combine(state, "sessions");
        if (!Directory.Exists(previous) && !File.Exists(previous)) return;
        PlainDirectory(state);
        PlainDirectory(previous);
        if (Directory.Exists(current) || File.Exists(current))
            throw new IOException("Both the old and current session stores exist; resolve the conflict before starting Loom");
        Directory.Move(previous, current);
    }

    void ArchiveMailbox() {
        string inbox = Path.Combine(ipc, "mailbox");
        if (!Directory.Exists(inbox)) return;
        string archive = Path.Combine(Setting("logs"), "interrupted-commands");
        string results = Path.Combine(ipc, "results");
        Directory.CreateDirectory(archive);
        Directory.CreateDirectory(results);
        foreach (string command in Directory.GetFiles(inbox, "*.st")) {
            string name = Path.GetFileName(command);
            File.Move(command, Path.Combine(archive, Guid.NewGuid().ToString("D") + "-" + name));
            string receipt = Path.Combine(results, Path.GetFileNameWithoutExtension(name) + ".json");
            if (!File.Exists(receipt)) Write(receipt, new {
                ok = false, error = "RUNTIME_INTERRUPTED", message = "Previous runtime command was interrupted and was not replayed"
            });
        }
    }

    string Receipt(string id) { return Path.Combine(ipc, "checkpoint-results", id + ".json"); }

    public bool HasPendingCheckpoint() {
        return Directory.EnumerateFiles(Path.Combine(ipc, "checkpoint-requests"), "*.json").Any(file =>
            IsId(Path.GetFileNameWithoutExtension(file)) &&
            !File.Exists(Receipt(Path.GetFileNameWithoutExtension(file))) &&
            DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromSeconds(90));
    }

    public void SealReadyCheckpoints() {
        foreach (string marker in Directory.GetFiles(Path.Combine(ipc, "checkpoint-saved"), "*.json")) {
            string id = Path.GetFileNameWithoutExtension(marker);
            if (!IsId(id) || File.Exists(Receipt(id))) continue;
            if (!File.Exists(Path.Combine(ipc, "checkpoint-requests", id + ".json"))) continue;
            try {
                Seal(id);
            } catch (Exception error) {
                Write(Receipt(id), new { ok = false, id, error = error.Message });
                Supervisor.Log(root, "Checkpoint " + id + ": " + error);
            }
        }
    }

    void Seal(string id) {
        string folder = Path.Combine(checkpoints, id);
        PlainDirectory(checkpoints);
        if (Directory.Exists(folder)) throw new IOException("Checkpoint generation already exists");
        Directory.CreateDirectory(folder);
        string image = Path.Combine(folder, "resume.image"), changes = Path.ChangeExtension(image, ".changes");
        Copy(WorkingImage, image);
        Copy(Path.ChangeExtension(WorkingImage, ".changes"), changes);
        var committed = new Dictionary<string,object> {
            {"id",id}, {"image",Path.Combine("state","runtime","checkpoints",id,"resume.image")},
            {"sha256",Hash(image)}, {"changesSha256",Hash(changes)}, {"committedAt",DateTime.UtcNow.ToString("o")}
        };
        Write(pointer, committed);
        CommittedImage = image;
        var result = new Dictionary<string,object>(committed);
        result["ok"] = true;
        Write(Receipt(id), result);
        var removed = new List<string>();
        var errors = new List<string>();
        foreach (string old in Directory.GetDirectories(checkpoints)) {
            if (String.Equals(folder, old, StringComparison.OrdinalIgnoreCase) || !IsId(Path.GetFileName(old))) continue;
            if ((File.GetAttributes(old) & FileAttributes.ReparsePoint) != 0) continue;
            if ((string)Read(pointer)["id"] != id) break;
            try { RemoveGeneration(old); removed.Add(old); }
            catch (Exception error) { errors.Add(error.Message); }
        }
        try { Write(Path.Combine(Setting("logs"), "checkpoint-retention.json"),
            new { retained = id, removed, errors, checkedAt = DateTime.UtcNow.ToString("o") }); }
        catch (Exception error) { Supervisor.Log(root, error.Message); }
    }

    void RemoveGeneration(string folder) {
        if (!folder.StartsWith(checkpoints + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Checkpoint cleanup outside managed directory");
        foreach (string file in Directory.GetFiles(folder)) File.Delete(file);
        foreach (string child in Directory.GetDirectories(folder)) {
            if ((File.GetAttributes(child) & FileAttributes.ReparsePoint) != 0) Directory.Delete(child);
            else RemoveGeneration(child);
        }
        Directory.Delete(folder);
    }
}
