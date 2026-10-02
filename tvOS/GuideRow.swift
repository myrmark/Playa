import PlayaCore
import SwiftUI

/// Half-hour marks on the same scale `GuideRow` draws its programmes with.
struct GuideRuler: View {
    let windowStart: Date
    let windowLength: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let inset = GuideRow.horizontalInset + GuideRow.nameWidth
            let timelineWidth = max(geometry.size.width - inset - GuideRow.horizontalInset, 1)
            let ticks = Int(windowLength / 1800)
            ForEach(0..<ticks, id: \.self) { tick in
                Text(windowStart.addingTimeInterval(Double(tick) * 1800).formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: inset + timelineWidth * CGFloat(tick) / CGFloat(ticks))
            }
        }
        .frame(height: 44)
    }
}

/// One channel's name and its programmes as blocks along the time axis.
struct GuideRow: View {
    let name: String
    let programmes: ArraySlice<Programme>
    let windowStart: Date
    let windowEnd: Date
    let now: Date

    /// Width of the channel-name column.
    static let nameWidth: CGFloat = 320
    /// Space a list leaves on each side of a row's content.
    static let horizontalInset: CGFloat = 20

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        // A focused row turns light, so its contents switch to dark.
        let ink: Color = isFocused ? .black : .white
        HStack(spacing: 0) {
            Text(name)
                .lineLimit(1)
                .frame(width: Self.nameWidth - 20, alignment: .leading)
                .padding(.trailing, 20)
            Canvas { context, size in
                let span = windowEnd.timeIntervalSince(windowStart)
                func x(_ date: Date) -> CGFloat {
                    size.width * CGFloat(min(max(date.timeIntervalSince(windowStart) / span, 0), 1))
                }
                if programmes.isEmpty {
                    context.draw(
                        Text("No programme information").font(.caption).foregroundStyle(ink.opacity(0.4)),
                        at: CGPoint(x: 14, y: size.height / 2), anchor: .leading
                    )
                }
                for programme in programmes {
                    let block = CGRect(x: x(programme.start) + 2, y: 4, width: max(x(programme.stop) - x(programme.start) - 4, 0), height: size.height - 8)
                    guard block.width > 2 else { continue }
                    let isOnNow = programme.start <= now && now < programme.stop
                    context.fill(
                        Path(roundedRect: block, cornerRadius: 10),
                        with: .color(isOnNow ? Color.accentColor.opacity(isFocused ? 0.45 : 0.4) : ink.opacity(0.1))
                    )
                    guard block.width > 60 else { continue }
                    var text = context
                    text.clip(to: Path(block.insetBy(dx: 12, dy: 0)))
                    text.draw(
                        Text(programme.title).font(.caption).foregroundStyle(ink),
                        at: CGPoint(x: block.minX + 14, y: block.minY + 10), anchor: .topLeading
                    )
                    text.draw(
                        Text(programme.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(ink.opacity(0.6)),
                        at: CGPoint(x: block.minX + 14, y: block.maxY - 10), anchor: .bottomLeading
                    )
                }
                if windowStart <= now, now < windowEnd {
                    context.fill(Path(CGRect(x: x(now) - 2, y: 0, width: 4, height: size.height)), with: .color(.red))
                }
            }
        }
        .frame(height: 96)
    }
}
