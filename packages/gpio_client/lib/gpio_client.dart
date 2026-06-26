/// Raspberry Pi GPIO controller input for Loopy.
///
/// Reads footswitch pin edges over a libgpiod FFI seam (`GpioBindings`,
/// implemented on-device by `LibGpiodBindings`) and adapts them to the
/// controller abstraction as a `GpioControllerSource` (implements
/// `ControllerSource`), so a floor-console pedal can drive the looper
/// hands-free. `createNativeGpioSource` builds it on a Pi and returns `null`
/// everywhere else.
library;

export 'src/gpio_bindings.dart' show GpioBindings, GpioEdgeCallback;
export 'src/gpio_controller_source.dart' show GpioControllerSource;
export 'src/lib_gpiod_bindings.dart' show GpioException, LibGpiodBindings;
export 'src/native_gpio_source.dart'
    show createNativeGpioSource, gpioDefaultLines;
