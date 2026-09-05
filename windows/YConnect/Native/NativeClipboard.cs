using System;
using System.Runtime.InteropServices;
using System.Text;

namespace YConnect.Native
{
    internal static class NativeClipboard
    {
        [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr owner);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint format, IntPtr memory);
        [DllImport("user32.dll")] private static extern bool CloseClipboard();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr memory);
        // CF_UNICODETEXT avoids OLE delayed rendering / clipboard-manager flush stalls.
        // Windows owns the allocation only after SetClipboardData succeeds.
        internal static void SetText(IntPtr owner, string value)
        {
            var bytes = Encoding.Unicode.GetBytes(value + "\0");
            var memory = GlobalAlloc(0x42, new UIntPtr((uint)bytes.Length));
            if (memory == IntPtr.Zero) throw new OutOfMemoryException();
            var opened = false;
            try
            {
                var address = GlobalLock(memory);
                if (address == IntPtr.Zero) throw new ExternalException("Clipboard memory unavailable");
                try { Marshal.Copy(bytes, 0, address, bytes.Length); } finally { GlobalUnlock(memory); }
                if (!(opened = OpenClipboard(owner))) throw new ExternalException("Clipboard busy");
                if (!EmptyClipboard() || SetClipboardData(13, memory) == IntPtr.Zero) throw new ExternalException("Clipboard write failed");
                memory = IntPtr.Zero;
            }
            finally { if (opened) CloseClipboard(); if (memory != IntPtr.Zero) GlobalFree(memory); }
        }
    }
}
