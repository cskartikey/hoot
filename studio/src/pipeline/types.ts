export interface ExplainRequest {
  question: string;
  brief?: string;
  spokenAnswer?: string;
  context?: {
    app?: string;
    youtube?: { videoId?: string; title?: string; t?: number; transcriptWindow?: string };
    screenText?: string;
  };
  memory?: { concept: string; summary: string }[];
  /** Who narrates the beats. Falls back to STUDIO_TTS_PROVIDER, then Cartesia. */
  ttsProvider?: TTSProvider;
}

export type TTSProvider = 'cartesia' | 'elevenlabs';

export interface Beat {
  id: number;
  narration: string;
  visual: string;
}

export type TemplateName = 'transform' | 'derivation' | 'process' | 'compare';

export interface Script {
  title: string;
  template: TemplateName;
  beats: Beat[];
}

export interface VoicedBeat extends Beat {
  audioPath: string;
  audioDur: number; // seconds of speech
  start: number; // planned slot start in the video (s)
  end: number; // planned slot end (speech + pause)
}

export interface Caption {
  start: number;
  end: number;
  text: string;
}
