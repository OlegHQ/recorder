import Foundation

/// SPEC §6.4: builds the initial `zooms` array for a finished recording from its click events.
/// `Edit ▸ Regenerate Auto Zooms` calls this again over the same `events.json`; `Edit ▸ Remove All
/// Zooms` just empties `project.zooms` (no call here).
public func generateAutoZooms(clicks: [InputEvent], duration: Double) -> [Zoom] {
    // 1. Left-button down events, oldest first (the input isn't guaranteed sorted).
    let downs = clicks.filter { $0.k == .down && $0.b == 0 }.sorted { $0.t < $1.t }

    // 2. Cluster: a click joins the current cluster if it's < 3 s after AND < 0.25 (normalised)
    // from the previous click; otherwise it starts a new cluster.
    var clusters: [[InputEvent]] = []
    for click in downs {
        if let prev = clusters.last?.last, click.t - prev.t < 3.0, normDistance(click, prev) < 0.25 {
            clusters[clusters.count - 1].append(click)
        } else {
            clusters.append([click])
        }
    }

    // 3. Each cluster becomes one zoom.
    let zooms = clusters.map { cluster in
        Zoom(start: cluster.first!.t - 0.4, end: cluster.last!.t + 1.5, scale: 2.0, mode: .auto)
    }

    // 4. Merge zooms whose gap is < 1.0 s. Clusters are already start-sorted, so a single linear
    // pass (classic interval merge) is enough.
    var merged: [Zoom] = []
    for zoom in zooms {
        if var last = merged.last, zoom.start - last.end < 1.0 {
            last.end = max(last.end, zoom.end)
            merged[merged.count - 1] = last
        } else {
            merged.append(zoom)
        }
    }

    // 5. Clamp to [0, duration] first, then drop anything left shorter than 1.0 s (clamping can
    // shrink a zoom below the threshold near the recording's edges).
    return merged.compactMap { zoom in
        var z = zoom
        z.start = min(max(z.start, 0), duration)
        z.end = min(max(z.end, 0), duration)
        return z.end - z.start >= 1.0 ? z : nil
    }
}

private func normDistance(_ a: InputEvent, _ b: InputEvent) -> Double {
    let dx = (a.x ?? 0) - (b.x ?? 0)
    let dy = (a.y ?? 0) - (b.y ?? 0)
    return (dx * dx + dy * dy).squareRoot()
}
