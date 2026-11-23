import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart' show operatingSystemProvider;
import '../state/streaming_asr_model_state.dart';
import '../state/streaming_asr_state.dart';
import 'native_trial.dart';
import 'streaming_asr_model.dart';

/// What live words run on here: HarmonyOS's own recognizer once its probe says
/// ready, the downloaded model elsewhere. Null when there is none; a failed
/// HarmonyOS probe throws, as the model store does.
Future<({StreamingAsrModel model, NativeTrial? trial})?> liveWordsModel(WidgetRef ref) async {
  if (ref.read(operatingSystemProvider) == 'ohos') {
    // The probe is autoDispose: held while it runs, re-asked next time.
    final probe = ref.listenManual(ohosStreamingAsrReadyProvider, (_, _) {});
    try {
      final ready = await ref.read(ohosStreamingAsrReadyProvider.future);
      return ready == SystemAsrReadiness.ready ? (model: const StreamingAsrModel.system(), trial: null) : null;
    } finally {
      probe.close();
    }
  }
  final models = await ref.read(streamingAsrModelStoreProvider.future);
  final model = await models.installed();
  return model == null ? null : (model: model, trial: models.trial);
}

/// [liveWordsModel] for what holds no widget (a call that outlives its page).
Future<({StreamingAsrModel model, NativeTrial? trial})?> liveWordsModelIn(ProviderContainer container) async {
  if (container.read(operatingSystemProvider) == 'ohos') {
    final probe = container.listen(ohosStreamingAsrReadyProvider, (_, _) {});
    try {
      final ready = await container.read(ohosStreamingAsrReadyProvider.future);
      return ready == SystemAsrReadiness.ready ? (model: const StreamingAsrModel.system(), trial: null) : null;
    } finally {
      probe.close();
    }
  }
  final models = await container.read(streamingAsrModelStoreProvider.future);
  final model = await models.installed();
  return model == null ? null : (model: model, trial: models.trial);
}
