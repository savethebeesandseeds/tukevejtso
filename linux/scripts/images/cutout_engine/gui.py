from __future__ import annotations

from pathlib import Path

from .pipeline import run_cutout
from .postprocess import checkerboard
from .types import CutoutOptions


def _pixmap_from_pil(image, max_width: int = 460, max_height: int = 520):
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QImage, QPixmap

    rgba = image.convert("RGBA")
    width, height = rgba.size
    data = rgba.tobytes("raw", "RGBA")
    qimage = QImage(data, width, height, QImage.Format.Format_RGBA8888).copy()
    pixmap = QPixmap.fromImage(qimage)
    return pixmap.scaled(
        max_width,
        max_height,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )


class CutoutWindow:
    def __init__(self):
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import (
            QCheckBox,
            QComboBox,
            QFileDialog,
            QFormLayout,
            QHBoxLayout,
            QLabel,
            QLineEdit,
            QMainWindow,
            QPushButton,
            QSplitter,
            QVBoxLayout,
            QWidget,
        )

        self.Qt = Qt
        self.QFileDialog = QFileDialog
        self.window = QMainWindow()
        self.window.setWindowTitle("tukevejtso cutout")
        self.window.resize(1160, 720)

        self.input_path = QLineEdit()
        self.output_path = QLineEdit()
        self.engine = QComboBox()
        self.engine.addItems(["auto", "classic", "birefnet"])
        self.preset = QComboBox()
        self.preset.addItems(["balanced", "fast", "pro"])
        self.device = QComboBox()
        self.device.addItems(["auto", "cpu", "cuda"])
        self.save_extras = QCheckBox("alpha, mask, diagnostics, previews")
        self.save_extras.setChecked(True)
        self.status = QLabel("Ready")
        self.status.setWordWrap(True)

        open_button = QPushButton("Open")
        output_button = QPushButton("Output")
        run_button = QPushButton("Run")
        open_button.clicked.connect(self.choose_input)
        output_button.clicked.connect(self.choose_output)
        run_button.clicked.connect(self.run)

        input_row = QHBoxLayout()
        input_row.addWidget(self.input_path)
        input_row.addWidget(open_button)
        output_row = QHBoxLayout()
        output_row.addWidget(self.output_path)
        output_row.addWidget(output_button)

        form = QFormLayout()
        form.addRow("Input", input_row)
        form.addRow("Output", output_row)
        form.addRow("Engine", self.engine)
        form.addRow("Preset", self.preset)
        form.addRow("Device", self.device)
        form.addRow("Save", self.save_extras)

        controls = QWidget()
        controls_layout = QVBoxLayout(controls)
        controls_layout.addLayout(form)
        controls_layout.addWidget(run_button)
        controls_layout.addWidget(self.status)
        controls_layout.addStretch(1)

        self.original_preview = QLabel("Original")
        self.result_preview = QLabel("Result")
        for label in (self.original_preview, self.result_preview):
            label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            label.setMinimumSize(420, 520)
            label.setStyleSheet("background: #1f2937; color: #f9fafb;")

        preview_panel = QWidget()
        preview_layout = QHBoxLayout(preview_panel)
        preview_layout.addWidget(self.original_preview)
        preview_layout.addWidget(self.result_preview)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(controls)
        splitter.addWidget(preview_panel)
        splitter.setSizes([320, 840])
        self.window.setCentralWidget(splitter)

    def choose_input(self) -> None:
        path, _ = self.QFileDialog.getOpenFileName(
            self.window,
            "Choose image",
            "",
            "Images (*.png *.jpg *.jpeg *.webp *.tif *.tiff *.bmp)",
        )
        if not path:
            return
        self.input_path.setText(path)
        if not self.output_path.text():
            input_path = Path(path)
            self.output_path.setText(str(input_path.with_name(f"{input_path.stem}_cutout.png")))
        self.load_original(Path(path))

    def choose_output(self) -> None:
        path, _ = self.QFileDialog.getSaveFileName(
            self.window,
            "Choose output PNG",
            self.output_path.text() or "",
            "PNG (*.png)",
        )
        if path:
            self.output_path.setText(path)

    def load_original(self, path: Path) -> None:
        try:
            from PIL import Image

            image = Image.open(path).convert("RGBA")
            self.original_preview.setPixmap(_pixmap_from_pil(image))
        except Exception as exc:
            self.status.setText(f"Could not load image: {exc}")

    def run(self) -> None:
        input_text = self.input_path.text().strip()
        output_text = self.output_path.text().strip()
        if not input_text or not output_text:
            self.status.setText("Choose input and output paths.")
            return

        input_path = Path(input_text)
        output_path = Path(output_text)
        options = CutoutOptions(
            engine=self.engine.currentText(),
            preset=self.preset.currentText(),
            device=self.device.currentText(),
        )
        try:
            result = run_cutout(input_path, options)
            alpha_output = None
            mask_output = None
            diagnostics_output = None
            if self.save_extras.isChecked():
                alpha_output = output_path.with_name(f"{output_path.stem}_alpha.png")
                mask_output = output_path.with_name(f"{output_path.stem}_mask.png")
                diagnostics_output = output_path.with_name(f"{output_path.stem}.json")
            result.save(output_path, alpha_output=alpha_output, mask_output=mask_output)
            if diagnostics_output is not None:
                import json

                diagnostics_output.write_text(
                    json.dumps(result.diagnostics, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            if self.save_extras.isChecked():
                preview_dir = output_path.with_name(f"{output_path.stem}_previews")
                preview_dir.mkdir(parents=True, exist_ok=True)
                from .postprocess import save_previews

                save_previews(result.rgba, preview_dir)

            board = checkerboard(result.rgba.size).convert("RGBA")
            from PIL import Image

            preview = Image.alpha_composite(board, result.rgba)
            self.result_preview.setPixmap(_pixmap_from_pil(preview))
            engine = result.diagnostics.get("engine", "unknown")
            self.status.setText(f"Saved {output_path} with {engine}.")
        except Exception as exc:
            self.status.setText(f"Cutout failed: {exc}")


def run_gui() -> int:
    try:
        from PySide6.QtWidgets import QApplication
    except ImportError as exc:
        raise RuntimeError(
            "The GUI needs PySide6. Install it with "
            "`./scripts/images/bootstrap_cutout_env.sh --gui`."
        ) from exc

    app = QApplication([])
    window = CutoutWindow()
    window.window.show()
    return app.exec()
