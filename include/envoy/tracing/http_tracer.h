#pragma once

#include <memory>
#include <string>
#include <vector>

#include "envoy/common/pure.h"
#include "envoy/http/access_log.h"
#include "envoy/http/header_map.h"

namespace Envoy {
namespace Tracing {

enum class OperationName { Ingress, Egress };

/*
 * Tracing configuration, it carries additional data needed to populate the span.
 */
class Config {
public:
  virtual ~Config() {}

  /**
   * @return operation name for tracing, e.g., ingress.
   */
  virtual OperationName operationName() const PURE;

  /**
   * @return list of headers to populate tags on the active span.
   */
  virtual const std::vector<Http::LowerCaseString>& requestHeadersForTags() const PURE;
};

class Span;

typedef std::unique_ptr<Span> SpanPtr;

/*
 * Interface to perform context-specific tasks when completing a Span.
 */
class SpanFinalizer {
public:
  virtual ~SpanFinalizer() {}

  /**
   * Finalize the Span.
   * @param span the Span to be finalized
   */
  virtual void finalize(Span& span) PURE;
};

/*
 * Basic abstraction for span.
 */
class Span {
public:
  virtual ~Span() {}

  /**
   * Attach metadata to a Span, to be handled in an implementation-dependent fashion.
   * @param name the name of the tag
   * @param value the value to associate with the tag
   */
  virtual void setTag(const std::string& name, const std::string& value) PURE;

  /**
   * Capture the final duration for this Span and carry out any work necessary to complete it.
   * Once this method is called, the Span may be safely discarded.
   * @param finalizer callback for context-specific work to complete the Span
   */
  virtual void finishSpan(SpanFinalizer& finalizer) PURE;

  /**
   * Mutate the provided headers with the context necessary to propagate this
   * (implementation-specific) trace.
   * @param request_headers the headers to which propagation context will be added
   */
  virtual void injectContext(Http::HeaderMap& request_headers) PURE;

  /**
   * Create and start a child Span, with this Span as its parent in the trace.
   * @param name operation name captured by the spawned child
   * @param start_time initial start time for the operation captured by the child
   */
  virtual SpanPtr spawnChild(const std::string& name, SystemTime start_time) PURE;
};

/**
 * Tracing driver is responsible for span creation.
 */
class Driver {
public:
  virtual ~Driver() {}

  /**
   * Start driver specific span.
   */
  virtual SpanPtr startSpan(Http::HeaderMap& request_headers, const std::string& operation_name,
                            SystemTime start_time) PURE;
};

typedef std::unique_ptr<Driver> DriverPtr;

/**
 * HttpTracer is responsible for handling traces and delegate actions to the
 * corresponding drivers.
 */
class HttpTracer {
public:
  virtual ~HttpTracer() {}

  virtual SpanPtr startSpan(const Config& config, Http::HeaderMap& request_headers,
                            const Http::AccessLog::RequestInfo& request_info) PURE;
};

typedef std::unique_ptr<HttpTracer> HttpTracerPtr;

} // namespace Tracing
} // namespace Envoy
