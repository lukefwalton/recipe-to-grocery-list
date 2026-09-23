import SwiftUI
import LFWDesignSystem

/// First-run walkthrough (spec §4.1): two pages on the family's onboarding
/// background — page one says what the app does, page two makes the privacy
/// promise in one breath, including the one page fetch, because that is the only
/// thing a privacy-minded user will wonder about. Built from the shared
/// `LFWDesignSystem` onboarding kit so it feels native to the family; the pager
/// shape is the workout app's `WorkoutOnboardingView`
/// (`WorkoutChatLog/App/WorkoutOnboardingView.swift` @5bffddfb80fc), the copy
/// rhythm the word app's intro pages. Finishing writes the flag through the model.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page = 0

    private let pageCount = 2

    var body: some View {
        ZStack {
            LFWOnboardingBackground()

            TabView(selection: $page) {
                OnboardingPage(
                    symbol: "cart",
                    eyebrow: "Recipe to Grocery List",
                    title: "Recipes in.\nOne list out.",
                    message: "Paste a recipe, share a link, or photograph a page. Confirm the ingredients, pick what you're cooking, shop from one merged list.",
                    cta: "Next",
                    action: { advance() }
                )
                .tag(0)

                OnboardingPage(
                    symbol: "lock.fill",
                    eyebrow: "Yours alone",
                    title: "Nothing leaves\nyour phone.",
                    message: "No account, no servers, no tracking, no cloud AI. When you give it a link, the app downloads that page, once, and nothing else.",
                    cta: "Get started",
                    action: { model.completeOnboarding() }
                )
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                LFWPageDots(count: pageCount, index: page)
                    .padding(.top, 10)
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }

    private func advance() {
        LFWHaptics.selection()
        withAnimation(.easeInOut) { page = min(page + 1, pageCount - 1) }
    }
}

/// One hero page: glyph, gold kicker, headline, message, pinned CTA pill.
private struct OnboardingPage: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let message: String
    let cta: String
    let action: () -> Void

    var body: some View {
        LFWOnboardingScaffold(symbol: symbol, eyebrow: eyebrow, title: title) {
            LFWOnboardingMessage(message)
        } footer: {
            Button(cta, action: action)
                .buttonStyle(.lfwCTA)
        }
    }
}
