import SwiftUI

struct NanoGridView: View {
    let tiles: [NanoTileModel]
    let onTap: (NanoTileModel) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tiles) { tile in
                NanoTile(model: tile)
                    .aspectRatio(1, contentMode: .fit)
                    .onTapGesture { onTap(tile) }
            }
        }
    }
}
