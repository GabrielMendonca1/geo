import Foundation

@MainActor
struct BlockLifecycleActions {
    let viewModel: BlocksViewModel

    init(viewModel: BlocksViewModel) {
        self.viewModel = viewModel
    }

    @discardableResult
    func archiveProject(blockId: String) async -> Bool {
        await viewModel.setStatus(.archived, for: blockId)
    }

    @discardableResult
    func extractPermanent(from project: BlockEntity) async -> BlockEntity? {
        let title = project.displayTitle
        let body = "Extraído de [[\(title)]]\n\n"
        guard let newBlock = await viewModel.createBlock(title: "", markdown: body) else {
            return nil
        }
        _ = await viewModel.setType(.permanent, for: newBlock.id)
        _ = await viewModel.setStatus(.archived, for: project.id)
        return newBlock
    }

    @discardableResult
    func promoteToPermanent(blockId: String) async -> Bool {
        let typeOK = await viewModel.setType(.permanent, for: blockId)
        let statusOK = await viewModel.setStatus(.evergreen, for: blockId)
        return typeOK && statusOK
    }

    func shouldConfirmDelete(_ block: BlockEntity) -> Bool {
        block.metadata.type == .permanent
    }
}
