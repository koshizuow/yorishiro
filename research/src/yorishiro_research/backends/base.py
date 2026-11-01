from typing import Protocol

import numpy as np


class Backend(Protocol):
    """Tensor in, tensor out. Pre/post-processing lives outside the backend."""

    name: str

    def run(self, inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]: ...
