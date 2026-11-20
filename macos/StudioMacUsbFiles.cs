using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

// All destination traversal is relative to a held mount descriptor. openat
// refuses symlinks; every directory stays on the verified device. Unplugging or
// replacing /Volumes/NAME cannot redirect cleanup to a new path or volume.
public sealed class RelayMacUsbVolume : IDisposable {
    const string Lib = "/usr/lib/libSystem.B.dylib";
    const int DirectoryFlag = 0x100000, NoFollow = 0x100, Create = 0x200, Exclusive = 0x800;
    const int NoFollowStat = 0x20, RemoveDirectory = 0x80;
    const ushort DirectoryMode = 0x4000, RegularMode = 0x8000, ModeMask = 0xf000;
    [StructLayout(LayoutKind.Sequential, Size = 144)]
    struct Stat {
        public int device; public ushort mode, links; public ulong inode;
        public uint uid, gid; public int rdev, pad;
        public long atime, atimeNano, mtime, mtimeNano, ctime, ctimeNano, birth, birthNano;
        public long size, blocks; public int blockSize; public uint flags, generation; public int spare;
        public long spare2, spare3;
    }
    [DllImport(Lib, SetLastError=true)] static extern int open(string path, int flags);
    [DllImport(Lib, SetLastError=true)] static extern int openat(int fd, string path, int flags, uint mode);
    [DllImport(Lib, SetLastError=true)] static extern int close(int fd);
    [DllImport(Lib, SetLastError=true)] static extern int dup(int fd);
    [DllImport(Lib, EntryPoint="fstat", SetLastError=true)] static extern int FStatArm(int fd, out Stat value);
    [DllImport(Lib, EntryPoint="fstat$INODE64", SetLastError=true)] static extern int FStatIntel(int fd, out Stat value);
    [DllImport(Lib, EntryPoint="stat", SetLastError=true)] static extern int StatArm(string path, out Stat value);
    [DllImport(Lib, EntryPoint="stat$INODE64", SetLastError=true)] static extern int StatIntel(string path, out Stat value);
    [DllImport(Lib, EntryPoint="fstatat", SetLastError=true)] static extern int FStatAtArm(int fd, string name, out Stat value, int flags);
    [DllImport(Lib, EntryPoint="fstatat$INODE64", SetLastError=true)] static extern int FStatAtIntel(int fd, string name, out Stat value, int flags);
    [DllImport(Lib, SetLastError=true)] static extern int mkdirat(int fd, string name, uint mode);
    [DllImport(Lib, SetLastError=true)] static extern int unlinkat(int fd, string name, int flags);
    [DllImport(Lib, SetLastError=true)] static extern int renameat(int from, string source, int to, string destination);
    [DllImport(Lib, EntryPoint="fdopendir", SetLastError=true)] static extern IntPtr OpenDirArm(int fd);
    [DllImport(Lib, EntryPoint="fdopendir$INODE64", SetLastError=true)] static extern IntPtr OpenDirIntel(int fd);
    [DllImport(Lib, EntryPoint="readdir", SetLastError=true)] static extern IntPtr ReadDirArm(IntPtr directory);
    [DllImport(Lib, EntryPoint="readdir$INODE64", SetLastError=true)] static extern IntPtr ReadDirIntel(IntPtr directory);
    [DllImport(Lib)] static extern int closedir(IntPtr directory);
    [DllImport(Lib)] static extern IntPtr realpath(string path, IntPtr buffer);
    [DllImport(Lib)] static extern void free(IntPtr buffer);
    static bool Intel => RuntimeInformation.ProcessArchitecture == Architecture.X64;
    static int fstat(int fd, out Stat value) => Intel ? FStatIntel(fd,out value) : FStatArm(fd,out value);
    static int stat(string path,out Stat value) => Intel ? StatIntel(path,out value) : StatArm(path,out value);
    static int fstatat(int fd,string name,out Stat value,int flags) => Intel ? FStatAtIntel(fd,name,out value,flags) : FStatAtArm(fd,name,out value,flags);
    static IntPtr readdir(IntPtr directory) => Intel ? ReadDirIntel(directory) : ReadDirArm(directory);
    static IntPtr fdopendir(int fd) => Intel ? OpenDirIntel(fd) : OpenDirArm(fd);
    int root; readonly int device;
    static IOException Error(string action) { return new IOException("USB " + action + " failed (macOS error " + Marshal.GetLastWin32Error() + "). The drive may have been removed or become read-only."); }
    static string[] Parts(string path) {
        if (String.IsNullOrEmpty(path) || path.StartsWith("/") || path.Contains("\\") || path.Contains("\0")) throw new IOException("Invalid USB path.");
        var parts = path.Split('/');
        foreach (var part in parts) if (part.Length == 0 || part == "." || part == "..") throw new IOException("Invalid USB path.");
        return parts;
    }
    static int Check(int result, string action) { if (result < 0) throw Error(action); return result; }
    static Stat Info(int fd) { Check(fstat(fd, out var value), "inspection"); return value; }
    void Verify(int fd, bool directory) {
        var value = Info(fd);
        if (value.device != device || (value.mode & ModeMask) != (directory ? DirectoryMode : RegularMode)) throw new IOException("A USB path changed, is a link, or crosses into another volume.");
    }
    public static string CanonicalPath(string path) {
        var value = realpath(path, IntPtr.Zero);
        if (value == IntPtr.Zero) throw Error("path resolution");
        try { return Marshal.PtrToStringUTF8(value); } finally { free(value); }
    }
    public static int DirectoryDevice(string path) {
        int fd = Check(open(path, DirectoryFlag | NoFollow), "directory inspection");
        try { return Info(fd).device; } finally { close(fd); }
    }
    public RelayMacUsbVolume(string mount, string deviceNode) {
        if (!mount.StartsWith("/Volumes/", StringComparison.Ordinal) || mount.Substring(9).Contains("/") || mount.Length <= 9 || !deviceNode.StartsWith("/dev/disk", StringComparison.Ordinal)) throw new IOException("Choose a mounted USB volume.");
        // realpath must match exactly: refuse linked mount names or ancestors.
        if (CanonicalPath(mount) != mount) throw new IOException("A USB mount path cannot be a link.");
        root = Check(open(mount, DirectoryFlag | NoFollow), "volume opening");
        try {
            var info = Info(root);
            Check(stat(deviceNode, out var node), "device inspection");
            if ((node.mode & ModeMask) != 0x6000 || info.device != node.rdev || (info.mode & ModeMask) != DirectoryMode) throw new IOException("The selected USB volume changed or was removed.");
            device = info.device;
        } catch { close(root); root = -1; throw; }
    }
    int Directory(string path, bool create) {
        int fd = Check(dup(root), "directory opening");
        try {
            if (path.Length > 0) foreach (var part in Parts(path)) {
                if (create && mkdirat(fd, part, 448) < 0 && Marshal.GetLastWin32Error() != 17) throw Error("directory creation");
                int child = Check(openat(fd, part, DirectoryFlag | NoFollow, 0), "directory opening");
                try { Verify(child, true); } catch { close(child); throw; }
                close(fd); fd = child;
            }
            return fd;
        } catch { close(fd); throw; }
    }
    int Parent(string path, out string leaf, bool create=false) {
        var parts = Parts(path); leaf = parts[parts.Length - 1];
        return Directory(parts.Length == 1 ? "" : String.Join("/", parts, 0, parts.Length - 1), create);
    }
    static string[] Entries(int fd) {
        int copy = Check(openat(fd,".",DirectoryFlag|NoFollow,0), "directory listing");
        IntPtr directory = fdopendir(copy);
        if (directory == IntPtr.Zero) { close(copy); throw Error("directory listing"); }
        var names = new List<string>();
        try {
            IntPtr entry;
            while ((entry = readdir(directory)) != IntPtr.Zero) {
                int length = (ushort)Marshal.ReadInt16(entry, 18);
                if (length < 1 || length > 1023) throw new IOException("Invalid USB directory entry.");
                var name = Marshal.PtrToStringUTF8(IntPtr.Add(entry,21), length);
                if (name != "." && name != "..") names.Add(name);
            }
        } finally { closedir(directory); }
        return names.ToArray();
    }
    public string[] List(string path) { int fd=Directory(path,false); try { return Entries(fd); } finally { close(fd); } }
    public void EnsureDirectory(string path) { close(Directory(path,true)); }
    public bool Exists(string path) {
        int fd;
        try { fd=Parent(path,out _); } catch(IOException) { return false; }
        try {
            string leaf=Parts(path)[Parts(path).Length-1];
            if(fstatat(fd,leaf,out _,NoFollowStat)==0)return true;
            if(Marshal.GetLastWin32Error()==2)return false;
            throw Error("entry inspection");
        } finally { close(fd); }
    }
    public void CopyFile(string source, string relative, string expectedHash) {
        int parent=Parent(relative,out string leaf,true), file=-1;
        try {
            file=Check(openat(parent,leaf,1|Create|Exclusive|NoFollow,384),"file creation");
            Verify(file,false);
            using(var handle=new SafeFileHandle((IntPtr)file,true)) {
                file=-1;
                using(var output=new FileStream(handle,FileAccess.Write))
                using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                    input.CopyTo(output); output.Flush(true);
                }
            }
            if(Hash(relative)!=expectedHash)throw new IOException("A copied USB file failed its checksum check.");
        } finally { if(file>=0)close(file); close(parent); }
    }
    public string Hash(string path) {
        int parent=Parent(path,out string leaf), file=-1;
        try {
            file=Check(openat(parent,leaf,NoFollow,0),"file reading"); Verify(file,false);
            using(var handle=new SafeFileHandle((IntPtr)file,true)) {
                file=-1; using(var stream=new FileStream(handle,FileAccess.Read))
                using(var hash=SHA256.Create()) return Convert.ToHexString(hash.ComputeHash(stream)).ToLowerInvariant();
            }
        } finally { if(file>=0)close(file); close(parent); }
    }
    public byte[] ReadBytes(string path,int maximum) {
        int parent=Parent(path,out string leaf),file=-1;
        try {
            file=Check(openat(parent,leaf,NoFollow,0),"file reading");Verify(file,false);
            if(Info(file).size>maximum)throw new IOException("The USB file is too large.");
            using(var handle=new SafeFileHandle((IntPtr)file,true)) {
                file=-1; using(var stream=new FileStream(handle,FileAccess.Read))
                using(var output=new MemoryStream()) {
                    var buffer=new byte[16384];int count;
                    while((count=stream.Read(buffer,0,buffer.Length))>0) {
                        if(output.Length+count>maximum)throw new IOException("The USB file grew unexpectedly.");
                        output.Write(buffer,0,count);
                    }
                    return output.ToArray();
                }
            }
        } finally { if(file>=0)close(file);close(parent); }
    }
    public void Move(string source,string destination) {
        int from=Parent(source,out string oldName),to=-1;
        try {
            to=Parent(destination,out string newName,true);
            if(fstatat(to,newName,out _,NoFollowStat)==0 || Marshal.GetLastWin32Error()!=2)throw new IOException("The USB destination already exists or cannot be checked.");
            Check(fstatat(from,oldName,out var item,NoFollowStat),"move inspection");
            if(item.device!=device)throw new IOException("A USB entry is on another volume.");
            Check(renameat(from,oldName,to,newName),"file move");
        } finally {close(from);if(to>=0)close(to);}
    }
    void Remove(int parent,string name) {
        Check(fstatat(parent,name,out var info,NoFollowStat),"cleanup inspection");
        if(info.device!=device)throw new IOException("Refusing to clear a nested volume.");
        bool directory=(info.mode&ModeMask)==DirectoryMode;
        if(directory) {
            int child=Check(openat(parent,name,DirectoryFlag|NoFollow,0),"cleanup directory opening");
            try { Verify(child,true);foreach(var entry in Entries(child))Remove(child,entry); } finally {close(child);}
        }
        Check(unlinkat(parent,name,directory?RemoveDirectory:0),"file cleanup");
    }
    public void Delete(string path) {int parent=Parent(path,out string leaf);try{Remove(parent,leaf);}finally{close(parent);}}
    long Allocation(int parent,string name) {
        Check(fstatat(parent,name,out var info,NoFollowStat),"space inspection");
        if(info.device!=device)throw new IOException("A USB directory contains a nested volume.");
        if((info.mode&ModeMask)==DirectoryMode) {
            int child=Check(openat(parent,name,DirectoryFlag|NoFollow,0),"space inspection");
            try {Verify(child,true);long total=0;foreach(var entry in Entries(child))total+=Allocation(child,entry);return total;}finally{close(child);}
        }
        return (info.mode&ModeMask)==RegularMode && info.links==1 ? info.blocks*512 : 0;
    }
    public long Reclaimable(string path) {int parent=Parent(path,out string leaf);try{return Allocation(parent,leaf);}finally{close(parent);}}
    public void Dispose() {if(root>=0){close(root);root=-1;}}
}

// Shared package validation only needs this hashing helper on macOS.
public static class RelayUsbFiles {
    public static string Hash(string path,string algorithm) {
        using(var file=File.OpenRead(path))
        using(HashAlgorithm hash=algorithm=="MD5"?(HashAlgorithm)MD5.Create():SHA256.Create())
            return Convert.ToHexString(hash.ComputeHash(file)).ToLowerInvariant();
    }
}
