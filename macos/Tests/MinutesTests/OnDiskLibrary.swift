import Testing

/// Parent of every suite that reads or writes a library on disk. They share
/// `AppPaths.rootOverride`, a global, so running them alongside each other
/// let one suite's store write into another's scratch library. `.serialized`
/// here applies to every suite nested inside.
@Suite(.serialized)
enum OnDiskLibrary {}
