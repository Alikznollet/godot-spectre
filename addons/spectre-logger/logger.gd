extends Logger
class_name Spectre
## Custom Log class to aid in debugging.
##
## Heavily based on the Log.gd in https://forum.godotengine.org/t/how-to-use-the-new-logger-class-in-godot-4-5/127006
## Added Things like minimum Log Level to include, Threaded logging, etc...

enum Event {
	DEBUG,
	INFO,
	WARN,
	ERROR,
	CRITICAL,
	FORCE_FLUSH
}

enum Channel {
	GENERAL,
	PHYSICS,
	AUDIO,
	RENDER,
	NETWORK,
	UI,
	INPUT,
}

# Easier access to the Channel values from the outside.
const GENERAL := Channel.GENERAL
const PHYSICS := Channel.PHYSICS
const AUDIO := Channel.AUDIO
const RENDER := Channel.RENDER
const NETWORK := Channel.NETWORK
const UI := Channel.UI
const INPUT := Channel.INPUT
	
static var _log_dir: String = "user://logs/"
static var _log_extension: String = "log"

static var _max_log_files: int = 5
static var _max_buffer_size: int = 10

## You can switch this to false to hide the PID from being printed in the console.
## PID will not be logged to the file.
static var _show_pid_in_print: bool = false

## Whether to crash when a critical log is called.
## It's good practice to do this (FAIL FAST). So this is enabled by default.
## Can be disabled in the project settings
static var _crash_on_critical: bool = true

## Whether to include a shortened trace in all logs.
## By default on in debug builds but can be turned off in the project settings.
## Forced off in production builds.
static var _include_shortened_trace: bool = true

## Which events cause a flush to the log file.
const _FLUSH_EVENTS: PackedByteArray = [
	Event.ERROR,
	Event.CRITICAL,
	Event.FORCE_FLUSH
]

## Colors associated with each event.
static var _event_colors: Dictionary[Event, String] = {
	Event.DEBUG: "light_blue",
	Event.INFO: "dark_sea_green",
	Event.WARN: "golden_rod",
	Event.ERROR: "tomato",
	Event.CRITICAL: "crimson"
}

static var _event_strings: PackedStringArray = Event.keys()
static var _channel_strings: PackedStringArray = Channel.keys()

static var _pid: int
static var _log_file: FileAccess
static var _thread: Thread
static var _semaphore: Semaphore
static var _mutex: Mutex = Mutex.new()
static var _exit_thread: bool = false
static var _message_queue: Array[Dictionary] = []
static var _is_logger_active: bool = false

## Minimum log level to include in the log file.
static var _min_log_level: Event = Event.DEBUG

## The Channels that are currently being logged.
## Allows for coarser logging when the issue is known to be in a certain sub-system.
static var _active_channels: Array = Channel.values()

static func _static_init() -> void:
	# Load project settings.
	var is_enabled: bool = ProjectSettings.get_setting(SpectrePaths.LOG_ENABLED_SETTING, true)
	_log_dir = ProjectSettings.get_setting(SpectrePaths.LOG_DIR_SETTING, "user://logs/")
	_log_extension = ProjectSettings.get_setting(SpectrePaths.LOG_EXTENSION_SETTING, "log")
	_max_log_files = ProjectSettings.get_setting(SpectrePaths.MAX_FILES_SETTING, 5)
	_max_buffer_size = ProjectSettings.get_setting(SpectrePaths.MAX_BUFFER_SIZE_SETTING, 10)
	_show_pid_in_print = ProjectSettings.get_setting(SpectrePaths.SHOW_PID_IN_PRINT_SETTING, false)
	_include_shortened_trace = ProjectSettings.get_setting(SpectrePaths.INCLUDE_SHORTENED_TRACE, true) and OS.is_debug_build() # We force it off if no debug build.
	_crash_on_critical = ProjectSettings.get_setting(SpectrePaths.CRASH_ON_CRITICAL_SETTING, true)
	_min_log_level = ProjectSettings.get_setting(SpectrePaths.MIN_LOG_LEVEL_SETTING, Event.DEBUG)

	# Load logger colors
	var c_debug: Color = ProjectSettings.get_setting(SpectrePaths.COLOR_DEBUG_SETTING, Color.LIGHT_BLUE)
	var c_info: Color = ProjectSettings.get_setting(SpectrePaths.COLOR_INFO_SETTING, Color.DARK_SEA_GREEN)
	var c_warn: Color = ProjectSettings.get_setting(SpectrePaths.COLOR_WARN_SETTING, Color.GOLDENROD)
	var c_error: Color = ProjectSettings.get_setting(SpectrePaths.COLOR_ERROR_SETTING, Color.TOMATO)
	var c_critical: Color = ProjectSettings.get_setting(SpectrePaths.COLOR_CRITICAL_SETTING, Color.CRIMSON)

	_event_colors[Event.DEBUG] = "#" + c_debug.to_html(false)
	_event_colors[Event.INFO] = "#" + c_info.to_html(false)
	_event_colors[Event.WARN] = "#" + c_warn.to_html(false)
	_event_colors[Event.ERROR] = "#" + c_error.to_html(false)
	_event_colors[Event.CRITICAL] = "#" + c_critical.to_html(false)

	# Set up the channel filters
	var channel_mask: int = ProjectSettings.get_setting(SpectrePaths.ACTIVE_CHANNELS_SETTING, 127)
	_active_channels.clear()

	# Unpack bitmask
	for i in range(Channel.size()):
		if channel_mask & (1 << i): 
			_active_channels.append(i as Channel)

	# If disabled just stop initialization
	if not is_enabled:
		return

	if not OS.is_debug_build():
		_min_log_level = Event.INFO # If Release build only include INFO and up.

	_pid = OS.get_process_id()
	_log_file = _create_log_file()
	var is_valid: bool = _log_file and _log_file.is_open()
	if is_valid:
		_is_logger_active = true

		_semaphore = Semaphore.new()
		_thread = Thread.new()
		_thread.start(_thread_worker)

		OS.add_logger(Spectre.new())
		info("Logger Initialized...")

		_remove_old_log_files()

## Creates a new log file for the current Date and Time.
static func _create_log_file() -> FileAccess:
	# Create the logging directory if it does not exist yet.
	if not DirAccess.dir_exists_absolute(_log_dir):
		DirAccess.make_dir_recursive_absolute(_log_dir)

	# Create a file_name based on time and process ID, so multiple DEBUG sessions can be started.
	var file_name := "%s_%d.%s" % [Time.get_datetime_string_from_system().replace(":", "-"), _pid, _log_extension]
	var file_path := _log_dir.path_join(file_name)
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	return file

## Removes the oldest log files when the amount exceeds _max_log_files
static func _remove_old_log_files() -> void:
	var log_file_paths: Array[String] = []

	for file: String in DirAccess.get_files_at(_log_dir):
		if file.get_extension().to_lower() == _log_extension:
			log_file_paths.append(_log_dir.path_join(file))

	# Sort alphabetically.
	log_file_paths.sort()

	while log_file_paths.size() > _max_log_files:
		var path: String = log_file_paths.pop_front()
		var err := DirAccess.remove_absolute(path)
		if err:
			error("Failed to clean up old log (%s): %s" % [error_string(err), path])
		else:
			info("Cleaned up old log: %s" % path)

# -- Helper Functions -- #

## Returns a GDScript Backtrace that can be used in the logs.
static func _get_gdscript_backtrace(script_backtraces: Array[ScriptBacktrace]) -> String:
	var gdscript := script_backtraces.find_custom(func(backtrace: ScriptBacktrace) -> bool:
		return backtrace.get_language_name() == "GDScript")
	return "Backtrace N/A" if gdscript == -1 else str(script_backtraces[gdscript])

## Formats a Log message properly.
static func _format_log_message(message: String, event: Event, channel: Channel) -> String:
	return "{shortened_trace}[{time}] [{event}] [{channel}] {message}".format({
		"shortened_trace": _get_shortened_trace(), # Could be empty if not a debug build.
		"time": _get_timestamp(),
		"event": _event_strings[event],
		"channel": _channel_strings[channel],
		"message": message
	})

## Returns either a string with a formatted shortened trace or an empty string.
static func _get_shortened_trace() -> String:
	var shortened_trace: String = ""
	if _include_shortened_trace:
		var stack = get_stack()
		if stack.size() > 0:
			var this_script_path: String = stack[0].source
			var caller: Dictionary = {}

			# We'll loop through the stack to find the first other script.
			for i in range(1, stack.size()):
				if stack[i].source != this_script_path:
					caller = stack[i]
					break
			
			if not caller.is_empty():
				var file_name: String = caller.source.get_file()
				var line_number: int = caller.line
				var func_name: String = caller.function
				shortened_trace = "[%s:%d in %s()] " % [file_name, line_number, func_name]

	return shortened_trace

## Returns a formatted timestamp including the current milliseconds.
static func _get_timestamp() -> String:
	var dt = Time.get_datetime_dict_from_system()
	var unix_time = Time.get_unix_time_from_system()
	var ms = int((unix_time - int(unix_time)) * 1000)
	return "%02d:%02d:%02d.%03d" % [dt.hour, dt.minute, dt.second, ms]

# -- Engine Interception -- #

## Logs an actual engine error.
func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if not _is_logger_active:
		return
	var event := Event.WARN if error_type == ERROR_TYPE_WARNING else Event.ERROR
	var message := "[{time}] [{event}] [{channel}] {rationale}\n{code}\n{file}:{line} @ {function}()".format({
		"time": _get_timestamp(),
		"event": _event_strings[event],
		"rationale": rationale,
		"code": code,
		"file": file,
		"line": line,
		"function": function,
		"channel": _channel_strings[Channel.GENERAL]
 	})
	if event == Event.ERROR:
		message += '\n' + _get_gdscript_backtrace(script_backtraces)
	_add_message_to_file_queue(message, event)

func _log_message(message: String, log_message_error: bool) -> void:
	if not _is_logger_active or message.begins_with("[lang=tlh]"):
		return
	var event := Event.ERROR if log_message_error else Event.INFO
	message = _format_log_message(message.trim_suffix('\n'), event, Channel.GENERAL)
	_add_message_to_file_queue(message, event)

# -- Custom Logging -- #

## Logs a specific message using it's event and channel values.
static func _log(message: String, event: Event, channel: Channel) -> void:
	if not _is_logger_active or event < _min_log_level or not channel in _active_channels: return

	message = _format_log_message(message, event, channel)

	if event >= Event.ERROR:
		var script_backtraces := Engine.capture_script_backtraces()
		message += '\n' + _get_gdscript_backtrace(script_backtraces)

	_add_message_to_file_queue(message, event)
	_print_event(message, event)

# Send and DEBUG message to the log. Default Channel is GENERAL.
static func debug(message: String, channel: Channel = Channel.GENERAL) -> void:
	_log(message, Event.DEBUG, channel)

# Send and INFO message to the log. Default Channel is GENERAL.
static func info(message: String, channel: Channel = Channel.GENERAL) -> void:
	_log(message, Event.INFO, channel)

## Send a Warn message to the log. Default Channel is GENERAL.
static func warn(message: String, channel: Channel = Channel.GENERAL) -> void:
	_log(message, Event.WARN, channel)

## Send an Error message to the log. Default Channel is GENERAL.
static func error(message: String, channel: Channel = Channel.GENERAL) -> void:
	_log(message, Event.ERROR, channel)

## Send a Critical message to the log. Default Channel is GENERAL.
static func critical(message: String, channel: Channel = Channel.GENERAL) -> void:
	_log(message, Event.CRITICAL, channel)

	# Only crash when in debug mode AND the user left the setting checked.
	if OS.is_debug_build() and _crash_on_critical:
		OS.delay_msec(100)
		OS.crash("CRITICAL ERROR: " + message)

## Forcibly flush the log file.
static func force_flush() -> void:
	_add_message_to_file_queue("", Event.FORCE_FLUSH)

# -- Channel Muting/Un-muting -- #

## Mutes all channels (essentially stopping all logs)
static func mute_all() -> void:
	_active_channels.clear()

## Un-mutes all channels (essentially opening all logs)
static func unmute_all() -> void:
	_active_channels = Channel.values()

## Mutes a single channel, removing it's log output.
static func mute_channel(channel: Channel) -> void:
	_active_channels.erase(channel)

## Unmute a single channel, re-enabling it's log output.
static func unmute_channel(channel: Channel) -> void:
	_active_channels.append(channel)

# -- Printing & File -- #

## Adds a message to the log file, thread-safe.
static func _add_message_to_file_queue(message: String, event: Event) -> void:
	if not _is_logger_active: return

	_mutex.lock()
	var should_flush: bool = _FLUSH_EVENTS.has(event)
	_message_queue.append({"msg": message, "flush": should_flush})
	_mutex.unlock()

	_semaphore.post() # Wake up the worker.

## Prints a single message and event. Also adds the PID if required.
static func _print_event(message: String, event: Event) -> void:
	var message_lines := message.split("\n")

	var pid_tag: String = "[%d] " % _pid if _show_pid_in_print else ""
	message_lines[0] = "[b][color=%s]%s%s[/color][/b]" % [_event_colors[event], pid_tag, message_lines[0]]
	print_rich.call_deferred("[lang=tlh]%s[/lang]" % "\n".join(message_lines))

## -- Multi-Threading -- ##

## The Threaded worker that will write all of the logs to a file without blocking
## the main thread.
static func _thread_worker() -> void:
	var buffer_size: int = 0

	while true:
		_semaphore.wait()
		
		# Grab the lock and all needed variables.
		_mutex.lock()
		var should_exit = _exit_thread
		var local_queue = _message_queue.duplicate()
		_message_queue.clear()
		_mutex.unlock()

		if _log_file:
			for entry in local_queue:
				# If message is empty we don't have anything to store.
				if entry.msg:
					_log_file.store_line(entry.msg)
					buffer_size += 1

				# We flush if the message needs flushing or the buffer size is exceeded.
				if entry.flush or buffer_size >= _max_buffer_size:
					_log_file.flush()
					buffer_size = 0

		# If the worker was told to exit at the end we break out of the loop.
		if should_exit:
			break

# -- Shutdown -- #

## Safely shuts down the Logging Thread and the logger itself.
static func shutdown() -> void:
	if not _is_logger_active: return

	info("Shutting down logger...")

	# Force a flush.
	force_flush()

	_mutex.lock()
	_exit_thread = true
	_mutex.unlock()

	_semaphore.post() # Wake up the Thread one last time.
	_thread.wait_to_finish()

	if _log_file:
		_log_file.close()
	_is_logger_active = false

# -- Lifecycle -- #

## This runs when the Spectre instance created in _static_init is destroyed by the engine upon quitting.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		Spectre.shutdown()
