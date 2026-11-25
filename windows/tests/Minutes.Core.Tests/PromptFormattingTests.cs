using Minutes.Core.Prompts;

namespace Minutes.Core.Tests;

public class PromptFormattingTests
{
    /// <summary>
    /// Stored dates are UTC; Claude must see the user's wall-clock time, as on
    /// macOS. 14:30 UTC on 5 January is 08:30 in Chicago (CST, UTC−6).
    /// </summary>
    [Fact]
    public void DatesAreWrittenInTheUsersTimeZone()
    {
        var instant = DateTimeOffset.FromUnixTimeSeconds(1_767_623_400);
        var chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
        Assert.Equal("Monday 5 January 2026, 08:30",
                     PromptFormatting.Format(instant, "dddd d MMMM yyyy, HH:mm", chicago));
        Assert.Equal("2026-01-05 14:30", PromptFormatting.Format(instant, "yyyy-MM-dd HH:mm", TimeZoneInfo.Utc));
    }
}
