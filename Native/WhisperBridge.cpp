#include "whisper.h"
#include <atomic>
#include <algorithm>
#include <thread>
struct SMMWhisper { whisper_context * context; std::atomic<bool> canceled{false}; };
using Draft = void (*)(double, double, const char *, void *);
struct DraftState { Draft callback; void * user; };
static void quiet_log(enum ggml_log_level, const char *, void *) {}
extern "C" {
void * smm_whisper_open(const char * path, int gpu) {
    whisper_log_set(quiet_log, nullptr);
    auto p = whisper_context_default_params(); p.use_gpu = gpu != 0;
    auto ctx = whisper_init_from_file_with_params(path, p);
    return ctx ? new SMMWhisper{ctx} : nullptr;
}
void smm_whisper_close(void * value) { auto s = (SMMWhisper *)value; if (s) { whisper_free(s->context); delete s; } }
void smm_whisper_cancel(void * value) { if (value) ((SMMWhisper *)value)->canceled = true; }
int smm_whisper_run(void * value, const float * samples, int count, const char * language, Draft callback, void * user) {
    auto s = (SMMWhisper *)value; s->canceled = false;
    auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = std::max(1, std::min(4, (int)std::thread::hardware_concurrency()));
    p.language = language; p.no_context = true; p.print_special = false; p.print_progress = false;
    p.print_realtime = false; p.print_timestamps = false; p.suppress_blank = true; p.suppress_nst = true;
    p.abort_callback = [](void * state) -> bool { return ((SMMWhisper *)state)->canceled.load(); };
    p.abort_callback_user_data = s;
    DraftState draft{callback, user};
    p.new_segment_callback_user_data = &draft;
    p.new_segment_callback = [](whisper_context * ctx, whisper_state *, int n, void * state) {
        auto draft = (DraftState *)state; if (!draft->callback) return;
        for (int i = whisper_full_n_segments(ctx) - n; i < whisper_full_n_segments(ctx); ++i)
            draft->callback(whisper_full_get_segment_t0(ctx, i) / 100.0, whisper_full_get_segment_t1(ctx, i) / 100.0, whisper_full_get_segment_text(ctx, i), draft->user);
    };
    return whisper_full(s->context, p, samples, count);
}
int smm_whisper_count(void * value) { return whisper_full_n_segments(((SMMWhisper *)value)->context); }
const char * smm_whisper_text(void * value, int i) { return whisper_full_get_segment_text(((SMMWhisper *)value)->context, i); }
double smm_whisper_start(void * value, int i) { return whisper_full_get_segment_t0(((SMMWhisper *)value)->context, i) / 100.0; }
double smm_whisper_end(void * value, int i) { return whisper_full_get_segment_t1(((SMMWhisper *)value)->context, i) / 100.0; }
float smm_whisper_silence(void * value, int i) { return whisper_full_get_segment_no_speech_prob(((SMMWhisper *)value)->context, i); }
}
