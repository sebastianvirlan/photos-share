import SwiftUI

/// A segmented switch made of Liquid Glass, like the ones in Photos: a clear glass capsule with
/// a highlight that slides to the chosen option. Before iOS 26 it's a normal segmented control.
struct GlassSwitcher<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight

    var body: some View {
        if #available(iOS 26, *) {
            HStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { selection = option.value }
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(chosen ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                if chosen {
                                    Capsule()
                                        .fill(.primary.opacity(0.12))
                                        .matchedGeometryEffect(id: "highlight", in: highlight)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(4)
            .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}
