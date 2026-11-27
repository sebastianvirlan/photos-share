import SwiftUI
import UIKit

/// The photo grid, in UIKit: pinching re-lays the tiles out continuously between column counts
/// (an interactive layout transition, as in Photos), keeping the photo under the fingers in place.
/// Tiles are SwiftUI views, so opening a photo still zooms out of its tile.
struct PhotoCollection: UIViewRepresentable {
    let libraryID: String
    let assets: [Asset]
    let app: AppModel
    let zoom: Namespace.ID
    /// An item to bring to the top (the first of the month picked in Months).
    var jump: String?
    /// An item to keep in view while the viewer is open (swiping there).
    var follow: String?
    let summary: String
    let onOpen: (Int) -> Void
    @Environment(\.refresh) private var refresh

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GridView {
        let c = context.coordinator
        c.parent = self
        let layout = GridLayout()
        layout.columns = c.columns
        let view = GridView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.dataSource = c
        view.delegate = c
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "tile")
        view.register(UICollectionViewCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
                      withReuseIdentifier: "footer")
        view.topEdgeEffect.style = .soft     // the frosting under the top bar fades out, as in Photos
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:))))
        if refresh != nil {
            let control = UIRefreshControl()
            control.addTarget(c, action: #selector(Coordinator.refreshed(_:)), for: .valueChanged)
            view.refreshControl = control
        }
        c.view = view
        c.ids = assets.map(\.id)
        if let p = DebugLaunch.pinch {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                c.simulatePinch(scale: p.scale, at: CGPoint(x: p.x, y: p.y))
            }
        }
        return view
    }

    func updateUIView(_ view: GridView, context: Context) {
        let c = context.coordinator
        let oldSummary = c.parent.summary
        c.parent = self
        let ids = assets.map(\.id)
        if ids != c.ids || summary != oldSummary {
            c.ids = ids
            view.reloadData()
            view.scrolledToEnd = false      // newest at the bottom again, like Photos
        }
        if let jump, jump != c.lastJump {
            c.lastJump = jump
            c.scroll(to: jump, at: .top)
        }
        if follow != c.lastFollow {
            c.lastFollow = follow
            if let follow { c.scroll(to: follow, at: .centeredVertically) }
        }
    }

    /// Starts at the newest photos (the bottom), once laid out.
    final class GridView: UICollectionView {
        var scrolledToEnd = false

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !scrolledToEnd, bounds.height > 0, contentSize.height > 0 else { return }
            scrolledToEnd = true
            let bottom = contentSize.height - bounds.height + adjustedContentInset.bottom
            contentOffset.y = max(-adjustedContentInset.top, bottom)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: PhotoCollection!
        weak var view: GridView?
        var ids: [String] = []
        var lastJump: String?
        var lastFollow: String?
        /// The chosen column count; nil = the default for the width.
        var columns: Int?

        // MARK: Data

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.assets.count
        }

        func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath)
            let p = parent!
            let asset = p.assets[indexPath.item]
            cell.contentConfiguration = UIHostingConfiguration {
                Tile(libraryID: p.libraryID, asset: asset)
                    .matchedTransitionSource(id: asset.id, in: p.zoom)
                    .environment(p.app)
            }
            .margins(.all, 0)
            return cell
        }

        func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            let footer = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "footer", for: indexPath)
            let text = parent.summary
            (footer as? UICollectionViewCell)?.contentConfiguration = UIHostingConfiguration {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            return footer
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            parent.onOpen(indexPath.item)
        }

        @objc func refreshed(_ control: UIRefreshControl) {
            Task { @MainActor in
                await parent.refresh?()
                control.endRefreshing()
            }
        }

        func scroll(to id: String, at position: UICollectionView.ScrollPosition) {
            guard let view, let i = parent.assets.firstIndex(where: { $0.id == id }) else { return }
            view.layoutIfNeeded()
            view.scrollToItem(at: IndexPath(item: i, section: 0), at: position, animated: false)
        }

        // MARK: Pinch

        private var transition: UICollectionViewTransitionLayout?
        private var from = 0, to = 0
        /// The photo under the fingers, where on it they are, and where that is on screen.
        private var anchor: GridLayout.Anchor?

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch g.state {
            case .began:
                begin(at: g.location(in: view))
            case .changed:
                change(scale: g.scale, finger: g.location(in: view))
            case .ended:
                end(finish: (transition?.transitionProgress ?? 0) > 0.3)
            default:
                end(finish: false)
            }
        }

        func begin(at point: CGPoint) {
            guard let view, let layout = view.collectionViewLayout as? GridLayout, !parent.assets.isEmpty else { return }
            from = layout.currentColumns
            let index = view.indexPathForItem(at: point) ?? view.indexPathsForVisibleItems.min {
                distance($0, point) < distance($1, point)
            }
            guard let index, let frame = view.layoutAttributesForItem(at: index)?.frame else { return }
            anchor = GridLayout.Anchor(
                index: index,
                fraction: CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height),
                screen: CGPoint(x: point.x - view.contentOffset.x, y: point.y - view.contentOffset.y))
        }

        func change(scale: CGFloat, finger: CGPoint) {
            guard let view, var anchor else { return }
            if transition == nil {
                // The direction is decided by the first movement: apart = fewer, bigger tiles.
                guard abs(scale - 1) > 0.02, let layout = view.collectionViewLayout as? GridLayout else { return }
                let steps = layout.steps
                guard let i = steps.firstIndex(of: from) else { return }
                let target = scale > 1 ? steps[max(i - 1, 0)] : steps[min(i + 1, steps.count - 1)]
                guard target != from else { return }
                to = target
                let next = GridLayout()
                next.columns = target
                next.anchor = anchor
                layout.anchor = anchor          // used when a cancelled pinch springs back
                transition = view.startInteractiveTransition(to: next) { [weak self] completed, _ in
                    self?.ended(completed: completed)
                }
            }
            guard let transition else { return }
            // Progress follows the fingers: reaching the new tile size is 1.
            let ratio = CGFloat(from) / CGFloat(to)
            transition.transitionProgress = min(max((scale - 1) / (ratio - 1), 0), 1)
            transition.invalidateLayout()
            // Keep the photo under the fingers, which may also move.
            anchor.screen = CGPoint(x: finger.x - view.contentOffset.x, y: finger.y - view.contentOffset.y)
            self.anchor = anchor
            if let frame = transition.layoutAttributesForItem(at: anchor.index)?.frame {
                let y = frame.minY + anchor.fraction.y * frame.height - anchor.screen.y
                view.contentOffset.y = GridLayout.clamp(y, in: view, contentHeight: transition.collectionViewContentSize.height)
            }
            (transition.nextLayout as? GridLayout)?.anchor = anchor
            (transition.currentLayout as? GridLayout)?.anchor = anchor
        }

        func end(finish: Bool) {
            guard let view, transition != nil else { anchor = nil; return }
            if finish { view.finishInteractiveTransition() } else { view.cancelInteractiveTransition() }
        }

        private func ended(completed: Bool) {
            if completed { columns = to }
            (view?.collectionViewLayout as? GridLayout)?.anchor = nil
            transition = nil
            anchor = nil
        }

        /// Debug only: a pinch's effect without fingers (`PS_PINCH`), to check the anchoring.
        func simulatePinch(scale: CGFloat, at unit: CGPoint) {
            guard let view else { return }
            let visible = view.bounds.inset(by: view.adjustedContentInset)
            let point = CGPoint(x: visible.minX + unit.x * visible.width, y: visible.minY + unit.y * visible.height)
            begin(at: point)
            change(scale: scale, finger: point)
            end(finish: (transition?.transitionProgress ?? 0) > 0.3)
        }

        private func distance(_ index: IndexPath, _ point: CGPoint) -> CGFloat {
            guard let f = view?.layoutAttributesForItem(at: index)?.frame else { return .infinity }
            return hypot(f.midX - point.x, f.midY - point.y)
        }
    }
}

/// Square tiles in N columns, 2 points apart, with a footer for the counts.
final class GridLayout: UICollectionViewFlowLayout {
    struct Anchor {
        var index: IndexPath
        var fraction: CGPoint
        var screen: CGPoint
    }

    /// Chosen column count; nil = about 130-point tiles (3 on iPhone).
    var columns: Int?
    /// Where the photo under the fingers should end up when this layout takes over.
    var anchor: Anchor?
    static let spacing: CGFloat = 2

    /// Column steps that fit the width (tiles at least 40 points), like Photos' 1, 3, 5…
    var steps: [Int] {
        let width = collectionView?.bounds.width ?? 400
        return [1, 3, 5, 7, 9, 11, 13].filter { width / CGFloat($0) >= 40 }
    }

    var currentColumns: Int {
        if let columns { return columns }
        let ideal = (collectionView?.bounds.width ?? 400) / 130
        return steps.min { abs(CGFloat($0) - ideal) < abs(CGFloat($1) - ideal) } ?? 3
    }

    override func prepare() {
        let width = collectionView?.bounds.width ?? 0
        let n = CGFloat(currentColumns)
        let scale = collectionView?.traitCollection.displayScale ?? 3
        let side = floor((width - Self.spacing * (n - 1)) / n * scale) / scale
        itemSize = CGSize(width: max(side, 1), height: max(side, 1))
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        footerReferenceSize = CGSize(width: width, height: 52)
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
        guard let anchor, let view = collectionView,
              let frame = layoutAttributesForItem(at: anchor.index)?.frame else {
            return super.targetContentOffset(forProposedContentOffset: proposed)
        }
        let y = frame.minY + anchor.fraction.y * frame.height - anchor.screen.y
        return CGPoint(x: proposed.x, y: Self.clamp(y, in: view, contentHeight: collectionViewContentSize.height))
    }

    static func clamp(_ y: CGFloat, in view: UIScrollView, contentHeight: CGFloat) -> CGFloat {
        let top = -view.adjustedContentInset.top
        let bottom = contentHeight - view.bounds.height + view.adjustedContentInset.bottom
        return min(max(y, top), max(top, bottom))
    }
}
