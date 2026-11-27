using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace PetQuota;

internal sealed class WindowsSecrets : ISecrets
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public string Protect(string value) => Convert.ToBase64String(ConvertBlob(Encoding.UTF8.GetBytes(value), true));
    public string Reveal(string value) => Encoding.UTF8.GetString(ConvertBlob(Convert.FromBase64String(value), false));

    private static byte[] ConvertBlob(byte[] bytes, bool protect)
    {
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var input = new Blob { Size = bytes.Length, Data = pin.AddrOfPinnedObject() };
            Blob output;
            var ok = protect
                ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new CryptographicException("Windows 无法使用当前用户的凭据保护服务。");
            try { var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result; }
            finally { LocalFree(output.Data); }
        }
        finally { pin.Free(); CryptographicOperations.ZeroMemory(bytes); }
    }
}
