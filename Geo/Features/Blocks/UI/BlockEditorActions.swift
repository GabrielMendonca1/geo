import Combine
import Foundation

@MainActor
final class BlockEditorActions {
    let setFullWidth: (String, Bool) async -> Bool
    let setTag: (String, String?) async -> Bool
    let setType: (String, BlockType) async -> Bool
    let setStatusString: (String, String?) async -> Bool
    let setLayer: (String, BlockLayer) async -> Bool
    let createBlock: (String, String) async -> BlockEntity?
    let createTag: (String, TagColor) async -> Result<Tag, Error>
    let updateBlock: (String, String) async -> Bool
    let saveBlockSync: (String, String) -> Void
    let setFocusedBlock: (String) -> Void
    let clearFocusedBlock: (String) -> Void
    let resolveBlockByTitle: (String) -> BlockEntity?
    let currentTag: (String?) -> Tag?
    let resolvedTag: (BlockEntity) -> Tag?
    let allTags: () -> [Tag]
    let blocksSnapshot: () -> [BlockEntity]
    let lifecycleActions: () -> BlockLifecycleActions

    let focusedBlockPublisher: AnyPublisher<BlockEntity?, Never>
    let blocksCountPublisher: AnyPublisher<Int, Never>

    init(viewModel: BlocksViewModel, focusedId: String) {
        self.setFullWidth = { [weak viewModel] id, value in
            await viewModel?.setFullWidth(value, for: id) ?? false
        }
        self.setTag = { [weak viewModel] id, tagId in
            await viewModel?.setTag(tagId, for: id) ?? false
        }
        self.setType = { [weak viewModel] id, type in
            await viewModel?.setType(type, for: id) ?? false
        }
        self.setStatusString = { [weak viewModel] id, status in
            await viewModel?.setStatus(status, for: id) ?? false
        }
        self.setLayer = { [weak viewModel] id, layer in
            await viewModel?.setLayer(layer, for: id) ?? false
        }
        self.createBlock = { [weak viewModel] title, markdown in
            await viewModel?.createBlock(title: title, markdown: markdown)
        }
        self.createTag = { [weak viewModel] name, color in
            guard let viewModel else { return .failure(RepositoryError.invalidInput) }
            return await viewModel.createTag(name: name, color: color)
        }
        self.updateBlock = { [weak viewModel] id, markdown in
            await viewModel?.updateBlock(id: id, markdown: markdown) ?? false
        }
        self.saveBlockSync = { [weak viewModel] id, markdown in
            viewModel?.saveBlockSync(id: id, markdown: markdown)
        }
        self.setFocusedBlock = { [weak viewModel] id in
            viewModel?.setFocusedBlock(id)
        }
        self.clearFocusedBlock = { [weak viewModel] id in
            viewModel?.clearFocusedBlock(ifMatching: id)
        }
        self.resolveBlockByTitle = { [weak viewModel] normalizedTarget in
            viewModel?.blocks.first(where: {
                WikiTitleNormalizer.normalize($0.displayTitle) == normalizedTarget
                    || WikiTitleNormalizer.normalize($0.title) == normalizedTarget
            })
        }
        self.currentTag = { [weak viewModel] tagId in
            viewModel?.tag(for: tagId)
        }
        self.allTags = { [weak viewModel] in
            viewModel?.tags ?? []
        }
        self.blocksSnapshot = { [weak viewModel] in
            viewModel?.blocks ?? []
        }
        self.lifecycleActions = { [viewModel] in
            BlockLifecycleActions(viewModel: viewModel)
        }
        self.focusedBlockPublisher = viewModel.focusedBlockPublisher(id: focusedId)
        self.blocksCountPublisher = viewModel.blocksCountPublisher
    }
}
