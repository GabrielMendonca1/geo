import SwiftUI

// AttributionsView displays the attributions or credits for your app.
// You can reuse this as a template for any informational/credits view.
struct AttributionsView: View {
    var body: some View {
        // The content is scrollable vertically in case the attributions text is long.
        ScrollView(.vertical) {
            HStack {
                // Main text content stacked vertically and left-aligned.
                VStack(alignment: .leading, spacing: 20) {
                    // The section title ("Attributions"), bold and large.
                    Text("Attributions")
                        .font(.title)
                        .bold()
                    // Placeholder for the actual attributions or credits text.
                    Text("<Insert attributions here>")
                        .multilineTextAlignment(.leading)
                }
                Spacer() // Push content left, fill out the rest of the row.
            }
            // Expand the row across the available width of the scroll view.
            .frame(maxWidth: .infinity)
        }
        // Allow the view to expand to fill its parent window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Add some padding all around for better visual spacing.
        .padding()
    }
}

// Preview provider so you can see this view in Xcode's canvas.
struct AttributionsView_Previews: PreviewProvider {
    static var previews: some View {
        AttributionsView()
    }
}
