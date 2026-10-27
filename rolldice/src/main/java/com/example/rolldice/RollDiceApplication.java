package com.example.rolldice;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongHistogram;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import io.opentelemetry.exporter.otlp.logs.OtlpGrpcLogRecordExporter;
import io.opentelemetry.exporter.otlp.metrics.OtlpGrpcMetricExporter;
import io.opentelemetry.exporter.otlp.trace.OtlpGrpcSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.logs.SdkLoggerProvider;
import io.opentelemetry.sdk.logs.export.BatchLogRecordProcessor;
import io.opentelemetry.sdk.metrics.SdkMeterProvider;
import io.opentelemetry.sdk.metrics.export.PeriodicMetricReader;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.BatchSpanProcessor;
import java.time.Duration;
import java.util.concurrent.ThreadLocalRandom;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
public class RollDiceApplication {
  public static void main(String[] args) {
    SpringApplication.run(RollDiceApplication.class, args);
  }

  @Bean(destroyMethod = "close")
  OpenTelemetrySdk openTelemetry(
      @Value("${otel.exporter.otlp.endpoint}") String endpoint,
      @Value("${otel.service.name}") String serviceName) {
    Resource resource =
        Resource.getDefault()
            .merge(
                Resource.create(
                    Attributes.of(AttributeKey.stringKey("service.name"), serviceName)));

    SdkTracerProvider tracerProvider =
        SdkTracerProvider.builder()
            .setResource(resource)
            .addSpanProcessor(
                BatchSpanProcessor.builder(OtlpGrpcSpanExporter.builder().setEndpoint(endpoint).build())
                    .build())
            .build();
    SdkMeterProvider meterProvider =
        SdkMeterProvider.builder()
            .setResource(resource)
            .registerMetricReader(
                PeriodicMetricReader.builder(OtlpGrpcMetricExporter.builder().setEndpoint(endpoint).build())
                    .setInterval(Duration.ofSeconds(5))
                    .build())
            .build();
    SdkLoggerProvider loggerProvider =
        SdkLoggerProvider.builder()
            .setResource(resource)
            .addLogRecordProcessor(
                BatchLogRecordProcessor.builder(
                        OtlpGrpcLogRecordExporter.builder().setEndpoint(endpoint).build())
                    .build())
            .build();

    return OpenTelemetrySdk.builder()
        .setTracerProvider(tracerProvider)
        .setMeterProvider(meterProvider)
        .setLoggerProvider(loggerProvider)
        .buildAndRegisterGlobal();
  }
}

@RestController
class RollDiceController {
  private static final Logger logger = LoggerFactory.getLogger(RollDiceController.class);
  private static final AttributeKey<Long> ROLL_VALUE = AttributeKey.longKey("roll.value");

  private final Tracer tracer;
  private final LongCounter rolls;
  private final LongHistogram rollValue;

  RollDiceController(OpenTelemetry openTelemetry) {
    tracer = openTelemetry.getTracer("rolldice");
    rolls = openTelemetry.getMeter("rolldice").counterBuilder("rolldice.rolls").build();
    rollValue =
        openTelemetry
            .getMeter("rolldice")
            .histogramBuilder("rolldice.roll.value")
            .ofLongs()
            .setUnit("1")
            .build();
  }

  @GetMapping("/rolldice")
  RollResponse rollDice() {
    Span span = tracer.spanBuilder("rolldice.roll").setSpanKind(SpanKind.SERVER).startSpan();
    try (Scope ignored = span.makeCurrent()) {
      int value = ThreadLocalRandom.current().nextInt(1, 7);
      Attributes attributes = Attributes.of(ROLL_VALUE, (long) value);

      span.setAttribute("roll.value", value);
      rolls.add(1, attributes);
      rollValue.record(value, attributes);
      logger.info("Rolled dice value={}", value);

      return new RollResponse(value);
    } catch (RuntimeException exception) {
      span.recordException(exception);
      throw exception;
    } finally {
      span.end();
    }
  }

  record RollResponse(int value) {}
}
