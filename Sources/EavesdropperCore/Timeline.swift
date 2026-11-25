/// Frames of silence to write before a buffer that starts `elapsed` seconds into the recording, when the
/// file already holds `written` frames. Audio devices skip cycles (a system-audio tap does, measured
/// 23 s lost in 263 s), and appending only what arrives would pull everything after a gap earlier than
/// it happened; padding keeps the file on the wall clock, so both sides of a call line up.
/// Jitter under `tolerance` is ignored; one gap is capped at `maxGap` (e.g. the Mac slept mid-call).
public func silenceToInsert(written: Int64, elapsed: Double, sampleRate: Double,
                            tolerance: Double = 0.05, maxGap: Double = 60) -> Int64 {
    guard elapsed > 0, sampleRate > 0 else { return 0 }
    let gap = Int64(elapsed * sampleRate) - written
    guard Double(gap) > tolerance * sampleRate else { return 0 }
    return min(gap, Int64(maxGap * sampleRate))
}
