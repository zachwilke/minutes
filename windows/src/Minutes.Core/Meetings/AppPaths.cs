namespace Minutes.Core.Meetings;

/// <summary>
/// Where the library lives. Windows uses %APPDATA%; the macOS path is here too so
/// the pipeline can be exercised against a real macOS library during development.
/// </summary>
public static class AppPaths
{
    public static string SupportRoot { get; set; } = DefaultRoot();

    private static string DefaultRoot()
    {
        if (OperatingSystem.IsWindows())
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                                "Minutes");
        if (OperatingSystem.IsMacOS())
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                "Library", "Application Support", "Minutes");
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                            ".minutes");
    }

    public static string MeetingsRoot => Path.Combine(SupportRoot, "Meetings");
    public static string ModelsRoot => Path.Combine(SupportRoot, "Models");
    public static string LogsRoot => Path.Combine(SupportRoot, "Logs");

    public static string MeetingDirectory(Guid id) => Path.Combine(MeetingsRoot, Format(id));
    public static string MetadataFile(Guid id) => Path.Combine(MeetingDirectory(id), "meeting.json");
    public static string AudioFile(Guid id) => Path.Combine(MeetingDirectory(id), "audio.wav");
    public static string EnergyFile(Guid id) => Path.Combine(MeetingDirectory(id), "energy.bin");
    public static string SummaryFile(Guid id) => Path.Combine(MeetingDirectory(id), "summary.md");

    /// <summary>
    /// Directory names are uppercase UUIDs, because that is what Swift's
    /// UUID.uuidString produces and the directory name must match the id.
    /// </summary>
    public static string Format(Guid id) => id.ToString("D").ToUpperInvariant();

    public static void EnsureDirectories()
    {
        foreach (var directory in new[] { SupportRoot, MeetingsRoot, ModelsRoot, LogsRoot })
            Directory.CreateDirectory(directory);
    }
}

/// <summary>Reads the meeting library from disk.</summary>
public static class MeetingLibrary
{
    /// <summary>Every readable meeting, newest first.</summary>
    public static List<Meeting> LoadAll()
    {
        var meetings = new List<Meeting>();
        if (!Directory.Exists(AppPaths.MeetingsRoot)) return meetings;

        foreach (var directory in Directory.EnumerateDirectories(AppPaths.MeetingsRoot))
        {
            string file = Path.Combine(directory, "meeting.json");
            if (!File.Exists(file)) continue;
            try { meetings.Add(MeetingJson.Read(file)); }
            catch (Exception error)
            {
                // One unreadable meeting must not hide the rest of the library.
                Console.Error.WriteLine($"skipping {Path.GetFileName(directory)}: {error.Message}");
            }
        }
        return [.. meetings.OrderByDescending(m => m.StartedAt)];
    }
}
