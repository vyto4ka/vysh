part of 'session_view.dart';

/// Выделение пальцем (ручки, долгое нажатие), меню выделения, щипок для
/// размера шрифта и разбор указателей мыши/пальца.
mixin _PointerGestures on _SessionViewBase {
  void _onHandlePanStart(DragStartDetails details, {required bool start}) {
    final selection = _controller.selection;
    final geometry = _geometry;
    final terminal = _terminal;
    if (selection == null || geometry == null || terminal == null) return;

    _dismissselectionMenu();

    final range = selection.normalized;
    _isDraggingHandle = true;
    _draggingStartHandle = start;

    _dragFixedCell = start ? range.end : range.begin;
    final movingCell = start ? range.begin : range.end;

    final cellOffset = geometry.getOffset(movingCell);
    final textPoint = cellOffset + Offset(0, geometry.cellSize.height);

    final touchInTerminal = geometry.globalToLocal(
      details.globalPosition,
    );
    _dragTouchDeltaToTextPoint = touchInTerminal - textPoint;
  }

  void _onHandlePanUpdate(DragUpdateDetails details, {required bool start}) {
    final geometry = _geometry;
    final terminal = _terminal;
    final fixedCell = _dragFixedCell;
    final delta = _dragTouchDeltaToTextPoint;

    if (geometry == null ||
        terminal == null ||
        fixedCell == null ||
        delta == null ||
        !_isDraggingHandle ||
        _draggingStartHandle != start) {
      return;
    }

    final stackBox =
        _terminalStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox != null && _scrollController.hasClients) {
      final localInStack = stackBox.globalToLocal(details.globalPosition);
      if (localInStack.dy < 40 && _scrollController.offset > 0) {
        _scrollController.jumpTo(
          (_scrollController.offset - 20).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
        );
      } else if (localInStack.dy > stackBox.size.height - 40 &&
          _scrollController.offset <
              _scrollController.position.maxScrollExtent) {
        _scrollController.jumpTo(
          (_scrollController.offset + 20).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
        );
      }
    }

    final touchInTerminal = geometry.globalToLocal(
      details.globalPosition,
    );
    final targetPointInTerminal = touchInTerminal - delta;

    final cell = geometry.cellSize;
    final samplePoint = Offset(
      targetPointInTerminal.dx,
      targetPointInTerminal.dy - cell.height * 0.5,
    );

    final rawCell = geometry.getCellOffset(samplePoint);
    final maxRow = terminal.buffer.lines.length - 1;
    if (maxRow < 0) return;

    final clampedRow = rawCell.y.clamp(0, maxRow);
    final maxCol = terminal.viewWidth;
    final clampedCol = rawCell.x.clamp(0, maxCol < 1 ? 0 : maxCol - 1);

    final movingCell = CellOffset(clampedCol, clampedRow);
    final buffer = terminal.buffer;

    if (start) {
      if (movingCell.isBefore(fixedCell)) {
        _controller.setSelection(
          buffer.createAnchorFromOffset(movingCell),
          buffer.createAnchorFromOffset(fixedCell),
        );
      } else {
        final endCol = (movingCell.x + 1).clamp(0, maxCol);
        _controller.setSelection(
          buffer.createAnchorFromOffset(fixedCell),
          buffer.createAnchor(endCol, movingCell.y),
        );
      }
    } else {
      if (movingCell.isAfterOrSame(fixedCell)) {
        final endCol = (movingCell.x + 1).clamp(0, maxCol);
        _controller.setSelection(
          buffer.createAnchorFromOffset(fixedCell),
          buffer.createAnchor(endCol, movingCell.y),
        );
      } else {
        final endCol = (fixedCell.x + 1).clamp(0, maxCol);
        _controller.setSelection(
          buffer.createAnchorFromOffset(movingCell),
          buffer.createAnchor(endCol, fixedCell.y),
        );
      }
    }
  }

  void _onHandlePanEnd(DragEndDetails details, {required bool start}) {
    _isDraggingHandle = false;
    _draggingStartHandle = null;
    _dragFixedCell = null;
    _dragTouchDeltaToTextPoint = null;

    if (ref.read(settingsProvider).copyOnSelect) {
      _copySelection();
    }

    if (mounted && _controller.selection != null) {
      final geometry = _geometry;
      final stackBox =
          _terminalStackKey.currentContext?.findRenderObject() as RenderBox?;
      if (geometry != null && stackBox != null) {
        final range = _controller.selection!.normalized;
        final endOffset = geometry.getOffset(range.end);
        final globalPos = geometry.localToGlobal(endOffset);
        final stackPos = stackBox.globalToLocal(globalPos);
        _showselectionMenu(stackPos);
      }
    }
  }

  void _onHandlePanCancel({required bool start}) {
    _isDraggingHandle = false;
    _draggingStartHandle = null;
    _dragFixedCell = null;
    _dragTouchDeltaToTextPoint = null;
  }

  Widget _selectionHandle({required bool start}) {
    final geometry = _geometry;
    final selection = _controller.selection;
    final terminal = _terminal;
    if (geometry == null || selection == null || terminal == null) {
      return const SizedBox.shrink();
    }

    final stackBox =
        _terminalStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) {
      return const SizedBox.shrink();
    }

    final range = selection.normalized;
    final anchorCell = start ? range.begin : range.end;

    if (anchorCell.y < 0 || anchorCell.y >= terminal.buffer.lines.length) {
      return const SizedBox.shrink();
    }

    final cell = geometry.cellSize;
    final handleType = start
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;

    final cellOffsetLocal = geometry.getOffset(anchorCell);
    final textPointLocal = cellOffsetLocal + Offset(0, cell.height);

    final textPointGlobal = geometry.localToGlobal(textPointLocal);
    final textPointInStack = stackBox.globalToLocal(textPointGlobal);

    const double touchSize = 48.0;
    const double handleSize = 22.0;
    const double pad = (touchSize - handleSize) / 2.0;

    final handleAnchor = MaterialTextSelectionControls().getHandleAnchor(
      handleType,
      cell.height,
    );

    final left = textPointInStack.dx - handleAnchor.dx - pad;
    final top = textPointInStack.dy - handleAnchor.dy - pad;

    return Positioned(
      key: ValueKey(start ? 'selection_handle_start' : 'selection_handle_end'),
      left: left,
      top: top,
      width: touchSize,
      height: touchSize,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                () => PanGestureRecognizer(
                  debugOwner: this,
                  supportedDevices: <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.unknown,
                    PointerDeviceKind.mouse,
                  },
                ),
                (PanGestureRecognizer instance) {
                  instance
                    ..dragStartBehavior = DragStartBehavior.down
                    ..gestureSettings = const DeviceGestureSettings(
                      touchSlop: 1.0,
                    )
                    ..onStart = (details) {
                      _onHandlePanStart(details, start: start);
                    }
                    ..onUpdate = (details) {
                      _onHandlePanUpdate(details, start: start);
                    }
                    ..onEnd = (details) {
                      _onHandlePanEnd(details, start: start);
                    }
                    ..onCancel = () {
                      _onHandlePanCancel(start: start);
                    };
                },
              ),
        },
        child: Padding(
          padding: const EdgeInsets.all(pad),
          child: MaterialTextSelectionControls().buildHandle(
            context,
            handleType,
            cell.height,
          ),
        ),
      ),
    );
  }

  Offset? _selectionMenuAnchor() {
    final selection = _controller.selection;
    final geometry = _geometry;
    final terminal = _terminal;
    final stackBox =
        _terminalStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (selection == null ||
        selection.isCollapsed ||
        geometry == null ||
        terminal == null ||
        stackBox == null ||
        !stackBox.hasSize) {
      return null;
    }

    final range = selection.normalized;
    final begin = range.begin;
    final end = range.end;
    if (begin.y < 0 ||
        end.y < 0 ||
        begin.y >= terminal.buffer.lines.length ||
        end.y >= terminal.buffer.lines.length) {
      return null;
    }

    Offset markerTop(CellOffset cellOffset, {required bool start}) {
      final cellSize = geometry.cellSize;
      final handleType = start
          ? TextSelectionHandleType.left
          : TextSelectionHandleType.right;
      final textPoint =
          geometry.getOffset(cellOffset) + Offset(0, cellSize.height);
      final anchor = MaterialTextSelectionControls().getHandleAnchor(
        handleType,
        cellSize.height,
      );
      const pad = 13.0;
      final inStack = stackBox.globalToLocal(
        geometry.localToGlobal(textPoint),
      );
      return Offset(inStack.dx - anchor.dx - pad, inStack.dy - anchor.dy - pad);
    }

    final startTop = markerTop(begin, start: true);
    final endTop = markerTop(end, start: false);
    final startX = stackBox
        .globalToLocal(
          geometry.localToGlobal(geometry.getOffset(begin)),
        )
        .dx;
    final endX = stackBox
        .globalToLocal(
          geometry.localToGlobal(geometry.getOffset(end)),
        )
        .dx;

    return Offset((startX + endX) / 2, math.min(startTop.dy, endTop.dy));
  }

  @override
  void _showselectionMenu(Offset position) {
    setState(() {
      _selectionMenuPosition = _selectionMenuAnchor() ?? position;
    });
  }

  @override
  void _dismissselectionMenu() {
    if (_selectionMenuPosition == null) {
      return;
    }

    setState(() {
      _selectionMenuPosition = null;
    });

    _focus.requestFocus();
  }

  double get _effectiveFontSize {
    final remember = ref.read(settingsProvider).rememberTerminalFontSize;
    if (_lastRememberFontSize != remember) {
      _lastRememberFontSize = remember;
      if (!remember) _sessionFontSize = 14;
    }
    return remember
        ? ref.read(settingsProvider).terminalFontSize
        : _sessionFontSize;
  }

  void _setFontSize(double value) {
    final next = value.clamp(8, 32).toDouble();
    if (ref.read(settingsProvider).rememberTerminalFontSize) {
      ref.read(settingsProvider.notifier).setTerminalFontSize(next);
    } else {
      setState(() => _sessionFontSize = next);
    }
  }

  void _cancelSinglePointerGesture() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _touchStartLocal = null;
    _touchStartGlobal = null;
    _isSelecting = false;
    _pinchBaseFontSize = _effectiveFontSize;
    _lastPinchFontSize = null;

    if (_controller.selection != null) {
      _controller.clearSelection();
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_activePointerIds.length < 2) {
      return;
    }

    _cancelSinglePointerGesture();
    _pinchBaseFontSize = _effectiveFontSize;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final base = _pinchBaseFontSize;
    if (_activePointerIds.length < 2 || base == null) {
      return;
    }

    final next = (base * details.scale).round().clamp(8, 32);
    if (next == _lastPinchFontSize) {
      return;
    }

    _lastPinchFontSize = next;
    _setFontSize(next.toDouble());
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _pinchBaseFontSize = null;
    _lastPinchFontSize = null;
  }

  /// Палец или кнопка мыши отпущены. Флаг снимаем кадром позже: двойной
  /// клик xterm2 ставит выделение уже после события отпускания.
  void _endUserSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_activePointerIds.isEmpty) _userSelecting = false;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _userSelecting = true;
    // Мышь (ПК): выделение без «уезжания» при прокрутке и вставка средней
    // кнопкой. Правый клик обрабатывает TerminalView.onSecondaryTapDown.
    // Жесты ниже (долгое нажатие, щипок) - только для пальца.
    if (event.kind == PointerDeviceKind.mouse) {
      if (ref.read(settingsProvider).middleClickPaste &&
          (event.buttons & kMiddleMouseButton) != 0) {
        _paste();
      }
      _dragFix.onPointerDown(event);
      return;
    }
    _activePointerIds.add(event.pointer);
    if (_activePointerIds.length >= 2) {
      _cancelSinglePointerGesture();
    }

    if ((event.buttons & kSecondaryMouseButton) != 0) {
      _onSecondaryClick(event.position, event.localPosition);
      return;
    }

    final terminal = _terminal;
    if (terminal != null && terminal.mouseMode != MouseMode.none) {
      return;
    }

    final geometry = _geometry;
    _touchStartLocal = geometry?.globalToLocal(event.position) ?? event.localPosition;
    _touchStartGlobal = event.position;
    _isSelecting = false;

    _longPressTimer?.cancel();

    _longPressTimer = Timer(
      const Duration(milliseconds: 380),
      _onLongPressTriggered,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _dragFix.onPointerMove(event);
      return;
    }
    if (_activePointerIds.length >= 2) {
      return;
    }

    if (_longPressTimer?.isActive == true) {
      final startGlobal = _touchStartGlobal;

      if (startGlobal != null &&
          (event.position - startGlobal).distance > 16.0) {
        _longPressTimer?.cancel();
        _longPressTimer = null;
      }
    } else if (_isSelecting) {
      final startLocal = _touchStartLocal;
      final geometry = _geometry;

      if (startLocal != null && geometry != null) {
        geometry.selectCharacters(
          startLocal,
          geometry.globalToLocal(event.position),
        );
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _endUserSelection();
    if (event.kind == PointerDeviceKind.mouse) {
      _dragFix.onPointerUp(event);
      return;
    }
    _activePointerIds.remove(event.pointer);
    if (_activePointerIds.isEmpty) {
      _pinchBaseFontSize = null;
      _lastPinchFontSize = null;
    }

    _longPressTimer?.cancel();
    _longPressTimer = null;

    if (_isSelecting) {
      _isSelecting = false;
      final stackBox =
          _terminalStackKey.currentContext?.findRenderObject() as RenderBox?;
      final pos = stackBox != null
          ? stackBox.globalToLocal(event.position)
          : event.localPosition;
      _showselectionMenu(pos);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _endUserSelection();
    if (event.kind == PointerDeviceKind.mouse) {
      _dragFix.onPointerUp(event);
      return;
    }
    _activePointerIds.remove(event.pointer);
    if (_activePointerIds.isEmpty) {
      _pinchBaseFontSize = null;
      _lastPinchFontSize = null;
    }

    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isSelecting = false;
  }

  void _onLongPressTriggered() {
    final startLocal = _touchStartLocal;
    final terminal = _terminal;
    final geometry = _geometry;

    if (startLocal == null || terminal == null || geometry == null) {
      return;
    }

    HapticFeedback.mediumImpact();

    final cellOffset = geometry.getCellOffset(startLocal);
    final wordBoundary = terminal.buffer.getWordBoundary(cellOffset);

    final wordText = wordBoundary != null
        ? terminal.buffer.getText(wordBoundary, true)
        : '';

    if (wordText.trim().isNotEmpty && wordBoundary != null) {
      _selectionIsEmptiness = false;
      _controller.setSelection(
        terminal.buffer.createAnchorFromOffset(wordBoundary.begin),
        terminal.buffer.createAnchorFromOffset(wordBoundary.end),
      );
    } else {
      _selectionIsEmptiness = true;
      _controller.setSelection(
        terminal.buffer.createAnchor(cellOffset.x, cellOffset.y),
        terminal.buffer.createAnchor(cellOffset.x + 1, cellOffset.y),
      );
    }

    _isSelecting = true;

    setState(() {
      _selectionMenuPosition = null;
    });
  }
}
