import SwiftUI

// AboutView is a SwiftUI View struct that displays app information in the About window.
struct AboutView: View {
    
    // Properties to display in the about dialog.
    let icon: NSImage           // App icon image.
    let name: String            // App name.
    let version: String         // App version string (e.g. "1.0").
    let build: String           // App build number (e.g. "100").
    let copyright: String       // Copyright information.
    let developerName: String   // Name of the developer shown in the dialog.
    
    // Main body of the SwiftUI view.
    var body: some View {
        VStack { // Stack vertically (top to bottom)
            HStack(alignment: .top) {
                // Show the app icon on the left
                Image(nsImage: icon)
                    .padding()
                // All app information shown in a vertical stack, aligned left
                VStack(alignment: .leading) {
                    // App name and version/build at the top, in a horizontal row
                    HStack(alignment: .firstTextBaseline) {
                        Text(name)
                            .font(.title)
                            .bold()
                        Spacer()
                        // Version and build info together
                        Text("Version \(version)") + Text(" (\(build))")
                    }
                    Divider()
                        .padding(.top, -8) // Pull divider closer to text above
                    // Show "Developed by" and the developer's name
                    Text("Developed by")
                        .bold()
                        .padding(.bottom, 2)
                    Text(developerName)
                        .padding(.bottom, 12)
                    Spacer()
                    // Copyright info at the bottom, smaller and lighter
                    Text(copyright)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }.padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 30))
            }
            // Row at the bottom for the Attributions button
            HStack {
                Spacer() // Pushes button to the right
                Button {
                    // When pressed, open the Attributions window.
                    AttributionsWindow.show()
                } label: {
                    Text("Attributions")
                }
            }
            .padding()
            .background(
                // Subtle background for the bottom row.
                Color(.sRGB, white: 0.0, opacity: 0.05)
            )
        }
    }
}
