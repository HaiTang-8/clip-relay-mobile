typedef RandomBytes = List<int> Function(int length);

const int relayVersion = 1;
const int keyBytes = 32;
const int saltBytes = 16;
const int nonceBytes = 12;
const int tagBytes = 16;
const int fingerprintBytes = 16;

const String labelFingerprint = 'clip-relay/v1/fpr';
const String labelWrap = 'clip-relay/v1/wrap';
const String labelPayload = 'clip-relay/v1/payload';
const String labelMeta = 'clip-relay/v1/meta';
const String labelBind = 'clip-relay/v1/bind';

const int frameSize = 64 * 1024;
const int frameCiphertextSize = frameSize + tagBytes;
const int blockFrames = 128;
const int blockSize = blockFrames * frameCiphertextSize;
const int inlineMaxBytes = 64 * 1024;
const Duration requestMaxSkew = Duration(minutes: 5);
