using System.Runtime.InteropServices;

namespace Minutes.Windows.Audio;

// COM declarations for the slice of WASAPI this needs. Vtable order is load
// bearing: these interfaces are declared in the exact order the headers define
// them, and a member inserted in the wrong place corrupts every call after it.
// Cross-check against mmdeviceapi.h and audioclient.h before editing.
//
// Every method is [PreserveSig]. Without it the runtime treats the declared
// int as a hidden [out, retval] and turns a failing HRESULT into an exception:
// every `Check(hr)` was dead code, and a device unplugged mid-call threw on the
// capture thread where nothing caught it.

internal enum DataFlow { Render = 0, Capture = 1 }
internal enum Role { Console = 0, Multimedia = 1, Communications = 2 }

internal enum AudClientShareMode { Shared = 0, Exclusive = 1 }

internal static class AudClientStreamFlags
{
    /// <summary>Capture what the endpoint is rendering — the system-audio tap.</summary>
    public const uint Loopback = 0x00020000;
    public const uint EventCallback = 0x00040000;
    public const uint AutoConvertPcm = 0x80000000;
    public const uint SrcDefaultQuality = 0x08000000;
}

internal static class AudClientBufferFlags
{
    public const uint DataDiscontinuity = 0x1;
    public const uint Silent = 0x2;
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints(DataFlow dataFlow, uint stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(DataFlow dataFlow, Role role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    [PreserveSig] int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
                 [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out uint state);
}

[ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioClient
{
    [PreserveSig] int Initialize(AudClientShareMode shareMode, uint streamFlags,
                   long bufferDuration, long periodicity,
                   IntPtr format, IntPtr sessionGuid);
    [PreserveSig] int GetBufferSize(out uint frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(AudClientShareMode shareMode, IntPtr format, out IntPtr closestMatch);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr handle);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioCaptureClient
{
    [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags,
                  out ulong devicePosition, out ulong qpcPosition);
    [PreserveSig] int ReleaseBuffer(uint frames);
    [PreserveSig] int GetNextPacketSize(out uint frames);
}

[StructLayout(LayoutKind.Sequential, Pack = 2)]
internal struct WaveFormatEx
{
    public ushort FormatTag;
    public ushort Channels;
    public uint SamplesPerSecond;
    public uint AverageBytesPerSecond;
    public ushort BlockAlign;
    public ushort BitsPerSample;
    public ushort ExtraSize;

    public const ushort PcmTag = 1;
    public const ushort FloatTag = 3;
    public const ushort ExtensibleTag = 0xFFFE;
}

internal static class Native
{
    [DllImport("ole32.dll")]
    public static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context,
                                              ref Guid iid, out IntPtr instance);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateEventW(IntPtr attributes, bool manualReset,
                                             bool initialState, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll")]
    public static extern bool QueryPerformanceFrequency(out long frequency);

    /// <summary>The endpoint went away — unplugged, disabled, or the default changed.</summary>
    public const int AudclntEDeviceInvalidated = unchecked((int)0x88890004);

    public const uint WaitObject0 = 0;
    public const uint WaitTimeout = 0x102;
}
