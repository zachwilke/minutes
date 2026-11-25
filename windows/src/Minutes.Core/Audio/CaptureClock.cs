using System.Diagnostics;

namespace Minutes.Core.Audio;

/// <summary>
/// The one clock capture timestamps and the drain both use: the performance
/// counter, in seconds. On Windows that is QPC, which is what WASAPI's
/// per-packet <c>qpcPosition</c> reports (in 100-ns units), so a buffer's
/// timestamp and the drain's "now" share an epoch.
/// </summary>
public static class CaptureClock
{
    public static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}
