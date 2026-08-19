import SwiftUI

// iOS 端:AI 研判术语速查。
// 内容全部来自 Core 的 ResearchTermGlossary,与 macOS「怎么读」同源,不另写文案。
struct IOSResearchTermGlossaryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("只给依据和条件，不替你做买卖决定；证据不足时宁可明说不足。所有结论都有时效，过期以失效条件为准。")
                    .font(.system(size: 13))
                    .foregroundColor(IOSDesign.muted)

                ForEach(ResearchTerm.allCases) { term in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(term.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(IOSDesign.ink)
                        Text(term.plainExplanation)
                            .font(.system(size: 12))
                            .foregroundColor(IOSDesign.muted)
                        Text(term.example)
                            .font(.system(size: 11))
                            .foregroundColor(IOSDesign.muted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
                }
            }
            .padding(16)
        }
        .navigationTitle("怎么读这份研判")
        .navigationBarTitleDisplayMode(.inline)
    }
}
