"""Render one scene file's Explainer class at 720p30 and print a plain (non-rich) traceback on failure.

usage: python runner.py <scene.py> <media_dir> [SceneName]
On success prints one line: RENDERED <path to mp4>
"""

import importlib.util
import sys
import traceback
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")


def main() -> int:
    scene_file = Path(sys.argv[1]).resolve()
    media_dir = sys.argv[2]
    scene_name = sys.argv[3] if len(sys.argv) > 3 else "Explainer"
    sys.path.insert(0, str(Path(__file__).parent))
    sys.path.insert(0, str(scene_file.parent))
    try:
        from manim import config, tempconfig

        opts = {
            "quality": "medium_quality",
            "media_dir": media_dir,
            "disable_caching": True,
            "progress_bar": "none",
            "verbosity": "WARNING",
            "output_file": scene_name,
            "write_to_movie": True,
        }
        with tempconfig(opts):
            spec = importlib.util.spec_from_file_location(scene_file.stem, scene_file)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[scene_file.stem] = mod
            spec.loader.exec_module(mod)
            config.pixel_width, config.pixel_height, config.frame_rate = 1280, 720, 30
            scene_cls = getattr(mod, scene_name)
            scene = scene_cls()
            scene.render()
            path = scene.renderer.file_writer.movie_file_path
        print(f"RENDERED {path}", flush=True)
        return 0
    except BaseException:
        tb = traceback.format_exc()
        # Keep the frames from the scene file and the final error; drop deep Manim internals.
        print(tb, file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
