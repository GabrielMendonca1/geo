import SwiftUI
import AppKit
import Foundation

struct NanoPane: View {
    @EnvironmentObject private var service: HermesStatusService
    @StateObject private var insights = TodayInsightsService()

    var body: some View {
        Pane {
            VStack(spacing: 0) {
                DashHeader(service: service, totalToday: insights.totalToday)
                Divider().overlay(Palette.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if service.setupState != .running {
                            HermesSetupBanner(service: service)
                        }

                        TodayCard(insights: insights)

                        HStack(alignment: .top, spacing: 24) {
                            ChannelsCard(service: service)
                            MemoryCard()
                        }

                        HStack(alignment: .top, spacing: 24) {
                            GeoCard { HermesCronsSection() }
                            GeoCard { WorkersCard() }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            insights.start()
        }
        .onDisappear {
            insights.stop()
        }
    }
}
