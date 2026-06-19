import SwiftUI
import SonosKit

struct GroupPickerView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Binding var selectedGroupID: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sonosManager.groups) { group in
                    Button {
                        selectedGroupID = group.id
                        NotificationCenter.default.post(name: .selectedGroupChanged, object: nil)
                    } label: {
                        Text(group.name)
                            .font(.subheadline)
                            .fontWeight(selectedGroupID == group.id ? .semibold : .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedGroupID == group.id
                                    ? Color.accentColor
                                    : Color(.systemGray5)
                            )
                            .foregroundStyle(selectedGroupID == group.id ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
