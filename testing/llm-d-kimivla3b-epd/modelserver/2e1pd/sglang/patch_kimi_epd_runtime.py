#!/usr/bin/env python3
"""Patch SGLang Kimi-VL E/PD encoder helpers at container startup.

The SGLang image used for this harness treats Kimi image grids as Qwen-style
``(t, h, w)`` in the batched encoder path. Kimi-VL emits ``(h, w)`` grids, so
the encoder crashes with ``index 2 is out of bounds`` before it can return
precomputed image embeddings to the decode worker.
"""

from pathlib import Path


TARGET = Path("/opt/sglang/python/sglang/srt/disaggregation/encode_server.py")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"could not find patch target: {label}")
    return text.replace(old, new, 1)


def main() -> None:
    text = TARGET.read_text()

    text = replace_once(
        text,
        """    if (model_type or "").lower() in [
        "kimi_k25",
        "kimi_vl",
    ] and modality == Modality.IMAGE:
        attrs = ("grid_thws", "image_grid_thw", "image_grid_hws")
""",
        """    if modality == Modality.IMAGE:
        model_type_l = (model_type or "").lower()
        if model_type_l == "kimi_vl":
            attrs = ("image_grid_hws", "image_grid_thw", "grid_thws")
        elif model_type_l == "kimi_k25":
            attrs = ("grid_thws", "image_grid_thw", "image_grid_hws")
""",
        "Kimi grid attr preference",
    )

    text = replace_once(
        text,
        """    for attr in attrs:
        if attr in mm_inputs and mm_inputs[attr] is not None:
            return mm_inputs[attr]
    raise ValueError(f"Grid dim ({_mm_grid_attrs[modality]}) not found in {mm_inputs}")
""",
        """    for attr in attrs:
        if attr in mm_inputs and mm_inputs[attr] is not None:
            return _convert(mm_inputs[attr])
    raise ValueError(f"Grid dim ({_mm_grid_attrs[modality]}) not found in {mm_inputs}")
""",
        "safe grid metadata serialization",
    )

    text = replace_once(
        text,
        """    def get_num_patches(
        self, grid: Union[torch.Tensor, List[int]], modality: Modality
    ) -> int:
        \"\"\"Calculate number of raw patches (before merge/sampling). Used for pixel_values slicing.\"\"\"
        if modality == Modality.AUDIO:
            return int(grid.item())
        else:
            return int(grid[0] * grid[1] * grid[2])

    def _kimi_tokens_from_patch_grid(self, grid: Union[torch.Tensor, List[int]]) -> int:
        \"\"\"MoonViT + tpool: output len is (h//mh)*(w//mw); temporal dim is pooled (not t*h*w/merge^2).\"\"\"
        if isinstance(grid, torch.Tensor):
            flat = grid.flatten()
            _t, h, w = (int(x) for x in flat[:3].tolist())
        else:
            _t, h, w = int(grid[0]), int(grid[1]), int(grid[2])
        merge_h, merge_w = self.model_config.hf_config.vision_config.merge_kernel_size
        return (h * w) // (merge_h * merge_w)
""",
        """    def get_num_patches(
        self, grid: Union[torch.Tensor, List[int]], modality: Modality
    ) -> int:
        \"\"\"Calculate number of raw patches (before merge/sampling). Used for pixel_values slicing.\"\"\"
        if modality == Modality.AUDIO:
            return int(grid.item())
        if (
            self.model_type in ["kimi_k25", "kimi_vl"]
            and modality == Modality.IMAGE
        ):
            h, w = self._kimi_hw_from_grid(grid)
            return h * w
        return int(grid[0] * grid[1] * grid[2])

    def _kimi_hw_from_grid(self, grid: Union[torch.Tensor, List[int]]) -> tuple[int, int]:
        \"\"\"Return Kimi image grid (h, w), accepting either (h, w) or (t, h, w).\"\"\"
        if isinstance(grid, torch.Tensor):
            vals = grid.flatten().tolist()
        elif isinstance(grid, np.ndarray):
            vals = grid.reshape(-1).tolist()
        else:
            vals = list(np.array(grid).reshape(-1).tolist())
        if len(vals) >= 3:
            h, w = vals[-2], vals[-1]
        elif len(vals) == 2:
            h, w = vals
        else:
            raise ValueError(
                f"Invalid Kimi image grid metadata: {vals}; expected [h,w] or [t,h,w]"
            )
        return int(h), int(w)

    def _kimi_tokens_from_patch_grid(self, grid: Union[torch.Tensor, List[int]]) -> int:
        \"\"\"MoonViT + tpool: output len is (h//mh)*(w//mw); temporal dim is pooled (not t*h*w/merge^2).\"\"\"
        h, w = self._kimi_hw_from_grid(grid)
        merge_h, merge_w = self.model_config.hf_config.vision_config.merge_kernel_size
        return (h * w) // (merge_h * merge_w)
""",
        "Kimi 2D grid patch/token counting",
    )

    TARGET.write_text(text)
    print(f"patched {TARGET} for Kimi-VL E/PD 2D image grids")


if __name__ == "__main__":
    main()
