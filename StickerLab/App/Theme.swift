import SwiftUI

// MARK: - Background

/// Soft colorful background: glass needs something behind it to refract.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                (scheme == .dark
                    ? Color(red: 0.05, green: 0.04, blue: 0.11)
                    : Color(red: 0.95, green: 0.94, blue: 1.0))
                blob(Color(red: 0.55, green: 0.30, blue: 0.95), size: w * 1.15)
                    .offset(x: -w * 0.35, y: -h * 0.32)
                blob(Color(red: 0.98, green: 0.35, blue: 0.65), size: w * 0.95)
                    .offset(x: w * 0.42, y: -h * 0.08)
                blob(Color(red: 0.25, green: 0.50, blue: 1.0), size: w * 1.05)
                    .offset(x: -w * 0.25, y: h * 0.30)
                blob(Color(red: 0.20, green: 0.80, blue: 0.75), size: w * 0.75)
                    .offset(x: w * 0.38, y: h * 0.42)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(scheme == .dark ? 0.42 : 0.30))
            .frame(width: size, height: size)
            .blur(radius: size * 0.32)
    }
}

// MARK: - Glass

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /// Liquid Glass on iOS 26, translucent material with a light rim before.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            legacyGlass(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        legacyGlass(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    /// Capsule-shaped glass (chips, badges, small bars).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
        }
        #else
        self.background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
        #endif
    }

    private func legacyGlass(cornerRadius: CGFloat, tint: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill((tint ?? .clear).opacity(0.22)))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        }
    }

    /// Glass button style (prominent = filled with tint).
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).optionalTint(tint)
            } else {
                self.buttonStyle(.glass).optionalTint(tint)
            }
        } else {
            legacyButton(prominent: prominent, tint: tint)
        }
        #else
        legacyButton(prominent: prominent, tint: tint)
        #endif
    }

    @ViewBuilder
    private func legacyButton(prominent: Bool, tint: Color?) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent).optionalTint(tint)
        } else {
            self.buttonStyle(.bordered).optionalTint(tint)
        }
    }

    @ViewBuilder
    func optionalTint(_ color: Color?) -> some View {
        if let color { self.tint(color) } else { self }
    }

    /// Colorful background behind a screen (and transparent lists/forms on top of it).
    func appBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background { AppBackground() }
    }

    /// Translucent rows for Form/List sections.
    func glassRows() -> some View {
        self.listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    /// iOS 26: the tab bar shrinks while scrolling down.
    @ViewBuilder
    func minimizingTabBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Groups glass elements so they blend together on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
