import SwiftUI

/// One month of photos: a run of `LibraryModel.photos`.
struct MonthGroup: Identifiable, Hashable {
    let id: String          // "2023-03"
    let year: Int
    let month: Int
    let assets: [Asset]

    var first: Asset { assets[0] }
    var title: String {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
        return date.formatted(.dateTime.month(.wide).year())
    }
    /// The place most of the month's photos were taken, if any have one.
    var place: String? {
        let counts = Dictionary(assets.compactMap(\.place).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }
    var cover: Asset { MonthGroup.cover(assets) }

    /// A favourite photo if there is one, else one from the middle; photos before videos.
    static func cover(_ assets: [Asset]) -> Asset {
        let stills = assets.filter { !$0.isVideo && $0.hasFile }
        let pool = stills.isEmpty ? assets : stills
        return pool.first(where: \.isFavorite) ?? pool[pool.count / 2]
    }

    /// Groups by the date as the photo recorded it (its own time zone, as Photos shows it).
    static func group(_ photos: [Asset]) -> [MonthGroup] {
        var order: [String] = []
        var byKey: [String: [Asset]] = [:]
        for a in photos {
            let key = String(a.d.prefix(7))
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(a)
        }
        return order.sorted().compactMap { key in
            let parts = key.split(separator: "-")
            guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), let items = byKey[key] else { return nil }
            return MonthGroup(id: key, year: y, month: m, assets: items)
        }
    }
}

struct YearGroup: Identifiable, Hashable {
    let year: Int
    let months: [MonthGroup]
    var id: Int { year }
    var count: Int { months.reduce(0) { $0 + $1.assets.count } }
    var cover: Asset { MonthGroup.cover(months.flatMap(\.assets)) }
}

/// Photos the way the Photos app shows them: Years, Months, or every photo.
struct PhotosTab: View {
    let model: LibraryModel
    @Binding var zoom: Zoom
    @State private var monthJump: String?
    @State private var photoJump: String?
    /// Set when a year or month card changes the view, rather than the switch at the top.
    @State private var fromCard = false

    enum Zoom: String, CaseIterable {
        case years, months, all
        var title: String { self == .all ? "All Photos" : rawValue.capitalized }
    }

    var body: some View {
        Group {
            switch zoom {
            case .years:
                YearsList(model: model) { year in
                    monthJump = year.months.first?.id
                    fromCard = true
                    withAnimation { zoom = .months }
                }
            case .months:
                MonthsList(model: model, jump: monthJump) { month in
                    photoJump = month.first.id
                    fromCard = true
                    withAnimation { zoom = .all }
                }
            case .all:
                PhotoGrid(libraryID: model.id, assets: model.photos,
                          downloads: model.detail?.downloads ?? false, jump: photoJump)
            }
        }
        // Picking from the switch at the top starts that view at its newest end.
        .onChange(of: zoom) {
            if !fromCard { monthJump = nil; photoJump = nil }
            fromCard = false
        }
    }
}

private struct YearsList: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel
    let pick: (YearGroup) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.years) { year in
                    Button { pick(year) } label: {
                        DateCard(url: app.api?.thumbURL(model.id, year.cover.u), title: String(year.year),
                                 subtitle: itemCount(year.count), big: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
    }
}

private struct MonthsList: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel
    let jump: String?
    let pick: (MonthGroup) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.months) { month in
                        if month.month == 1 || month.id == model.months.first?.id {
                            Text(String(month.year)).font(.title2.bold()).padding(.top, 8)
                        }
                        Button { pick(month) } label: {
                            DateCard(url: app.api?.thumbURL(model.id, month.cover.u), title: month.title,
                                     subtitle: [month.place, itemCount(month.assets.count)]
                                        .compactMap { $0 }.joined(separator: " · "), big: false)
                        }
                        .buttonStyle(.plain)
                        .id(month.id)
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .task(id: jump) {
                guard let jump else { return }
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo(jump, anchor: .top)
            }
        }
    }
}

/// A wide photo with the period written over it, like the cards in Photos.
private struct DateCard: View {
    let url: URL?
    let title: String
    let subtitle: String
    let big: Bool

    var body: some View {
        Color.clear
            .aspectRatio(big ? 1.25 : 1.6, contentMode: .fit)
            .overlay { if let url { RemoteImage(url: url, maxPixels: 900) } }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(big ? .largeTitle.bold() : .title2.bold())
                    Text(subtitle).font(.subheadline)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }
