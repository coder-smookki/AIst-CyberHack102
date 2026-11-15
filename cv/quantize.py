"""Сжатие модели ONNX: веса матричных умножений хранятся в int8, остальное остаётся в float32.

Запуск:
    python cv/quantize.py <модель.onnx> <куда.onnx>

Нужно для RF-DETR nano: в float32 файл занимает около 108 МБ, это больше предела GitHub на один файл.
Сведения о классах и размере входа переносятся в новый файл, чтобы его можно было загрузить так же,
как исходный. Точность сжатой модели нужно замерить заново (cv/compare.py), она может измениться.
"""

import os
import sys

import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic


def quantize(source: str, target: str) -> int:
    """Сжимает веса MatMul и Gemm до int8, переносит метаданные и возвращает размер файла в байтах."""
    quantize_dynamic(source, target, op_types_to_quantize=["MatMul", "Gemm"], weight_type=QuantType.QInt8)
    original = {item.key: item.value for item in onnx.load(source, load_external_data=False).metadata_props}
    model = onnx.load(target)
    present = {item.key for item in model.metadata_props}
    for key, value in original.items():
        if key not in present:
            model.metadata_props.add(key=key, value=value)
    onnx.save(model, target)
    return os.path.getsize(target)


if __name__ == "__main__":
    print(quantize(sys.argv[1], sys.argv[2]))
