import SwiftUI

// Liquid Glass on macOS 26+, for the controls layer only: the tab selection, buttons, the approval block and small
// status chips. Content (the day, activity, settings) stays on the panel's one surface. Older systems, older SDKs
// (Swift < 6.2) and Reduce Transparency get a frosted or solid fill in the same shape.

extension View {
    /// A glass shape behind this view (tinted when `tint` is given).
    @ViewBuilder
    func glassBackground(_ shape: some Shape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: AnyShape(shape), tint: tint, interactive: interactive))
    }

    /// Glass button style (prominent = tinted glass for the primary action).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }

    /// Ties this glass shape to `id` in `namespace`, so it morphs into the shape with the same id elsewhere.
    @ViewBuilder
    func glassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// Set while `--snapshot` draws views into bitmaps: the window server composites Liquid Glass, so a bitmap of the
    /// view never holds it (it comes out blank). Glass is then drawn as a tinted fill of the same shape.
    @Entry var drawsGlassAsFill = false
}

private struct GlassBackground: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.drawsGlassAsFill) private var drawsGlassAsFill

    func body(content: Content) -> some View {
        if drawsGlassAsFill {
            content.background {
                shape.fill(tint.map { $0.opacity(0.16) } ?? Color.primary.opacity(0.09))
                    .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        } else if reduceTransparency || contrast == .increased {
            // Solid, with a defined edge: legible over anything.
            content.background {
                shape.fill(tint.map { $0.opacity(0.22) } ?? Color.primary.opacity(0.10))
                    .overlay(shape.stroke((tint ?? .primary).opacity(contrast == .increased ? 0.8 : 0.3), lineWidth: 1))
            }
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = tint.map { Glass.regular.tint($0.opacity(0.3)) } ?? .regular
                content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
            } else {
                content.background { frosted }
            }
            #else
            content.background { frosted }
            #endif
        }
    }

    private var frosted: some View {
        shape.fill(.regularMaterial)
            .overlay(shape.fill((tint ?? .clear).opacity(0.14)))
            .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Groups glass shapes so they blend and morph together on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
