import SwiftUI

struct PendingAttachmentChip: View {
    let attachment: ChatMessage.Attachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isImage, let img = AttachmentRenderer.image(from: attachment.data) {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: attachment.isAudio ? "waveform.circle.fill" : "paperclip")
                            .font(.title3)
                        Text(attachment.filename)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 80, height: 56)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }
}
