require 'thread'
require 'set'
require 'base64'
require 'strscan'
require 'skylight/util/logging'

module Skylight
  # @api private
  class Instrumenter
    KEY  = :__skylight_current_trace
    LOCK = Mutex.new
    DESC_LOCK = Mutex.new

    TOO_MANY_UNIQUES = "<too many unique descriptions>"

    include Util::Logging

    class TraceInfo
      def current
        Thread.current[KEY]
      end

      def current=(trace)
        Thread.current[KEY] = trace
      end
    end

    def self.instance
      @instance
    end

    # Do start
    # @param [Config] config The config
    def self.start!(config = Config.new)
      return @instance if @instance

      LOCK.synchronize do
        return @instance if @instance
        @instance = new(config).start!
      end
    end

    def self.stop!
      LOCK.synchronize do
        return unless @instance
        # This is only really helpful for getting specs to pass.
        @instance.current_trace = nil

        @instance.shutdown
        @instance = nil
      end
    end

    attr_reader :config, :gc, :trace_info

    def initialize(config)
      if Hash === config
        config = Config.new(config)
      end

      @gc = config.gc
      @config = config
      @worker = config.worker.build
      @subscriber = Subscriber.new(config, self)

      @trace_info = @config[:trace_info] || TraceInfo.new
      @descriptions = Hash.new { |h,k| h[k] = {} }
      @active_traces = {}

      # Used for CPU profiling
      @app_root = config[:root]
      @run_profiler = false
      @timing_thread = nil
    end

    def current_trace
      @trace_info.current
    end

    def current_trace=(trace)
      @trace_info.current = trace
    end

    def start!
      return unless config

      unless Skylight.native?
        Skylight.warn_skylight_native_missing
        return
      end

      t { "starting instrumenter" }
      @config.validate!

      case @config.validate_token
      when :ok
        # Good to go
      when :unknown
        log_warn "unable to validate authentication token"
      else
        raise ConfigError, "authentication token is invalid"
      end

      @config.gc.enable

      unless @worker.spawn
        log_error "failed to spawn worker"
        return nil
      end

      @subscriber.register!

      start_cpu_profiler

      self

    rescue Exception => e
      log_error "failed to start instrumenter; msg=%s", e.message
      t { e.backtrace.join("\n") }
      nil
    end

    def shutdown
      log_debug "shutting down instrumenter"
      stop_cpu_profiler
      @subscriber.unregister!
      @worker.shutdown
    end

    def trace(endpoint, cat, title=nil, desc=nil, annot=nil)
      # If a trace is already in progress, continue with that one
      if trace = @trace_info.current
        t { "already tracing" }
        return yield(trace) if block_given?
        return trace
      end

      begin
        trace = Messages::Trace::Builder.new(self, endpoint, Util::Clock.nanos, cat, title, desc, annot)
      rescue Exception => e
        log_error e.message
        t { e.backtrace.join("\n") }
        return
      end

      @trace_info.current = trace
      register_trace(trace)

      return trace unless block_given?

      begin
        yield trace

      ensure
        @trace_info.current = nil
        trace.submit
      end
    end

    def disable
      @disabled = true
      yield
    ensure
      @disabled = false
    end

    def disabled?
      @disabled
    end

    @scanner = StringScanner.new('')
    def self.match?(string, regex)
      @scanner.string = string
      @scanner.match?(regex)
    end

    def match?(string, regex)
      self.class.match?(string, regex)
    end

    def done(span)
      return unless trace = @trace_info.current
      trace.done(span)
    end

    def instrument(cat, title=nil, desc=nil, annot=nil)
      raise ArgumentError, 'cat is required' unless cat

      unless trace = @trace_info.current
        return yield if block_given?
        return
      end

      cat = cat.to_s

      unless match?(cat, CATEGORY_REGEX)
        warn "invalid skylight instrumentation category; value=%s", cat
        return yield if block_given?
        return
      end

      cat = "other.#{cat}" unless match?(cat, TIER_REGEX)

      unless sp = trace.instrument(cat, title, desc, annot)
        return yield if block_given?
        return
      end

      return sp unless block_given?

      begin
        yield sp
      ensure
        trace.done(sp)
      end
    end

    def limited_description(description)
      endpoint = nil
      endpoint = @trace_info.current.endpoint

      DESC_LOCK.synchronize do
        set = @descriptions[endpoint]

        if set.size >= 100
          return TOO_MANY_UNIQUES
        end

        set[description] = true
        description
      end
    end

    def error(type, description, details=nil)
      t { fmt "processing error; type=%s; description=%s", type, description }

      message = Skylight::Messages::Error.build(type, description, details && details.to_json)

      unless @worker.submit(message)
        warn "failed to submit error to worker"
      end
    end

    def process(trace)
      t { fmt "processing trace" }
      unless @worker.submit(trace)
        warn "failed to submit trace to worker"
      end
    end

    def release(trace)
      LOCK.synchronize do
        if @active_traces[trace.thread] == trace
          @active_traces.delete(trace.thread)
        end
      end

      return unless current_trace == trace
      selfcurrent_trace = nil
    end

  # private

    def cpu_profiling?
      Skylight.cpu_profiling_supported?
    end

    def start_cpu_profiler
      if @config[:'features.cpu_profiling']
        unless cpu_profiling?
          log_warn "native Skylight agent compiled without CPU profiling."
          return
        end

        log_debug "starting CPU profiler"
        @run_profiler = true
        start_timing_thread
        native_start_cpu_profiler(Thread.current)
      end
    end

    def stop_cpu_profiler
      return unless @run_profiler
      return unless cpu_profiling?

      native_stop_cpu_profiler

      @run_profiler = false

      if @timing_thread
        @timing_thread.join(5)
        @timing_thread = nil
      end
    end

    def register_trace(trace)
      if @app_root
        trace.set_stack_frame_filter(@app_root)
      end

      LOCK.synchronize do
        @active_traces[trace.thread] = trace
      end
    end

    def sample_stacks
      # TODO: synchronization is not permitted in a signal handler, so obtain a
      # lock by running in C.
      @active_traces.each do |th, trace|
        if th.alive?
          trace.sample_stack(th)
        else
          @active_traces.delete(th)
        end
      end
    end

    def start_timing_thread
      # Running this simple no-op thread helps get more reliable timing when
      # taking CPU profiling samples
      Thread.new do
        while @run_profiler
          sleep 0.002
        end
      end
    end
  end
end
