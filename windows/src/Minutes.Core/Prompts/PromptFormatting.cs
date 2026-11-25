using System.Globalization;

namespace Minutes.Core.Prompts;

/// <summary>
/// How dates are written into prompts: the user's local time, with fixed
/// English names — matching macOS, which formats in the local time zone with
/// en_US_POSIX. Meeting dates are stored in UTC, so formatting them as stored
/// told Claude a 10:00 CDT meeting happened at 15:00.
/// </summary>
public static class PromptFormatting
{
    /// <summary>Local by default; the prompt audit pins it to UTC so the
    /// baseline does not depend on where it is run.</summary>
    public static TimeZoneInfo TimeZone { get; set; } = TimeZoneInfo.Local;

    public static string Format(DateTimeOffset instant, string pattern, TimeZoneInfo? zone = null)
        => TimeZoneInfo.ConvertTime(instant, zone ?? TimeZone).ToString(pattern, CultureInfo.InvariantCulture);
}
