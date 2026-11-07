import SwiftUI

// MARK: - Background

/// Pure black background on every screen.
struct AppBackground: View {
    var body: some View {
        Color.black
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    /// Adds a "hide keyboard" button above the keyboard and lets scrolling dismiss it.
    func keyboardDismissButton() -> some View {
        self.scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        hideKeyboard()
                    } label: {
                        Label("Nascondi tastiera", systemImage: "keyboard.chevron.compact.down")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
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
