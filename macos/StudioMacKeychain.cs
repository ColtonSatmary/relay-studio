using System;
using System.Runtime.InteropServices;
using System.Text;

// Use Security.framework in-process. Passwords never enter process arguments,
// environment variables, console output, preferences, or project exports.
public static class RelayMacKeychain {
    const string Security = "/System/Library/Frameworks/Security.framework/Security";
    const string Core = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    const int NotFound = -25300;
    static readonly byte[] Service = Encoding.UTF8.GetBytes("com.relay-studio.player-password");
    [DllImport(Security)] static extern int SecKeychainFindGenericPassword(IntPtr keychain, uint serviceLength, byte[] service, uint accountLength, byte[] account, out uint length, out IntPtr data, out IntPtr item);
    [DllImport(Security)] static extern int SecKeychainAddGenericPassword(IntPtr keychain, uint serviceLength, byte[] service, uint accountLength, byte[] account, uint length, byte[] data, out IntPtr item);
    [DllImport(Security)] static extern int SecKeychainItemModifyAttributesAndData(IntPtr item, IntPtr attributes, uint length, byte[] data);
    [DllImport(Security)] static extern int SecKeychainItemDelete(IntPtr item);
    [DllImport(Security)] static extern int SecKeychainItemFreeContent(IntPtr attributes, IntPtr data);
    [DllImport(Core)] static extern void CFRelease(IntPtr item);
    static void Check(int status) {
        if (status != 0) throw new InvalidOperationException("macOS Keychain could not access the saved player password (status " + status + "). Unlock your login keychain and allow Relay's PowerShell process access.");
    }
    public static string Read(string accountName) {
        byte[] account = Encoding.UTF8.GetBytes(accountName), copy = null;
        IntPtr data = IntPtr.Zero, item = IntPtr.Zero;
        try {
            int status = SecKeychainFindGenericPassword(IntPtr.Zero, (uint)Service.Length, Service, (uint)account.Length, account, out uint length, out data, out item);
            if (status == NotFound) return "";
            Check(status);
            if (length > 1024) throw new InvalidOperationException("The saved player password is too long. Save it again.");
            copy = new byte[length];
            if (length > 0) Marshal.Copy(data, copy, 0, (int)length);
            return new UTF8Encoding(false, true).GetString(copy);
        } finally {
            if (copy != null) Array.Clear(copy, 0, copy.Length);
            if (data != IntPtr.Zero) SecKeychainItemFreeContent(IntPtr.Zero, data);
            if (item != IntPtr.Zero) CFRelease(item);
        }
    }
    public static void Write(string accountName, string password) {
        byte[] account = Encoding.UTF8.GetBytes(accountName), bytes = Encoding.UTF8.GetBytes(password);
        IntPtr data = IntPtr.Zero, item = IntPtr.Zero;
        try {
            int status = SecKeychainFindGenericPassword(IntPtr.Zero, (uint)Service.Length, Service, (uint)account.Length, account, out uint length, out data, out item);
            if (data != IntPtr.Zero) { SecKeychainItemFreeContent(IntPtr.Zero, data); data = IntPtr.Zero; }
            if (status == NotFound) {
                if (bytes.Length == 0) return;
                Check(SecKeychainAddGenericPassword(IntPtr.Zero, (uint)Service.Length, Service, (uint)account.Length, account, (uint)bytes.Length, bytes, out item));
            } else {
                Check(status);
                Check(bytes.Length == 0 ? SecKeychainItemDelete(item) : SecKeychainItemModifyAttributesAndData(item, IntPtr.Zero, (uint)bytes.Length, bytes));
            }
        } finally {
            Array.Clear(bytes, 0, bytes.Length);
            if (data != IntPtr.Zero) SecKeychainItemFreeContent(IntPtr.Zero, data);
            if (item != IntPtr.Zero) CFRelease(item);
        }
    }
}
