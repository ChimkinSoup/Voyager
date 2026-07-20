import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/domain/models/settings_models.dart';

GeometricTextureParams geometricTextureParamsFromSettings(
  AppSettings settings,
) {
  return GeometricTextureParams(
    scale: settings.geometricTextureScale,
    intensity: settings.geometricTextureIntensity,
    focalSpread: settings.geometricTextureFocalSpread,
    focalPointX: settings.geometricTextureFocalPointX,
    focalPointY: settings.geometricTextureFocalPointY,
    variationFloor: settings.geometricTextureVariationFloor,
  );
}

AppSettings appSettingsWithGeometricTextureParams(
  AppSettings settings,
  GeometricTextureParams params,
) {
  return settings.copyWith(
    geometricTextureScale: params.scale,
    geometricTextureIntensity: params.intensity,
    geometricTextureFocalSpread: params.focalSpread,
    geometricTextureFocalPointX: params.focalPointX,
    geometricTextureFocalPointY: params.focalPointY,
    geometricTextureVariationFloor: params.variationFloor,
  );
}

GeometricWaveParams geometricWaveParamsFromSettings(AppSettings settings) {
  return GeometricWaveParams(
    enabled: settings.geometricWaveEnabled,
    shape: settings.geometricWaveShape,
    directionDegrees: settings.geometricWaveDirectionDegrees,
    speed: settings.geometricWaveSpeed,
    width: settings.geometricWaveWidth,
    period: settings.geometricWavePeriod,
    popHoldSeconds: settings.geometricWavePopHoldSeconds,
    popScale: settings.geometricWavePopScale,
    popBrightness: settings.geometricWavePopBrightness,
    maskDensity: settings.geometricWaveMaskDensity,
    maskClusterScale: settings.geometricWaveMaskClusterScale,
    twinkleSparsity: settings.geometricWaveTwinkleSparsity,
    shadowLightDegrees: settings.geometricWaveShadowLightDegrees,
    shadowOffset: settings.geometricWaveShadowOffset,
    shadowSoftness: settings.geometricWaveShadowSoftness,
    shadowStrength: settings.geometricWaveShadowStrength,
    popBrightnessVariance: settings.geometricWavePopBrightnessVariance,
    tiltAmount: settings.geometricWaveTiltAmount,
    tiltShading: settings.geometricWaveTiltShading,
    massLagSeconds: settings.geometricWaveMassLagSeconds,
    massSpring: settings.geometricWaveMassSpring,
    scatterMode: settings.geometricWaveScatterMode,
    scatterLitAmount: settings.geometricWaveScatterLitAmount,
  );
}

AppSettings appSettingsWithGeometricWaveParams(
  AppSettings settings,
  GeometricWaveParams params,
) {
  return settings.copyWith(
    geometricWaveEnabled: params.enabled,
    geometricWaveShape: params.shape,
    geometricWaveDirectionDegrees: params.directionDegrees,
    geometricWaveSpeed: params.speed,
    geometricWaveWidth: params.width,
    geometricWavePeriod: params.period,
    geometricWavePopHoldSeconds: params.popHoldSeconds,
    geometricWavePopScale: params.popScale,
    geometricWavePopBrightness: params.popBrightness,
    geometricWaveMaskDensity: params.maskDensity,
    geometricWaveMaskClusterScale: params.maskClusterScale,
    geometricWaveTwinkleSparsity: params.twinkleSparsity,
    geometricWaveShadowLightDegrees: params.shadowLightDegrees,
    geometricWaveShadowOffset: params.shadowOffset,
    geometricWaveShadowSoftness: params.shadowSoftness,
    geometricWaveShadowStrength: params.shadowStrength,
    geometricWavePopBrightnessVariance: params.popBrightnessVariance,
    geometricWaveTiltAmount: params.tiltAmount,
    geometricWaveTiltShading: params.tiltShading,
    geometricWaveMassLagSeconds: params.massLagSeconds,
    geometricWaveMassSpring: params.massSpring,
    geometricWaveScatterMode: params.scatterMode,
    geometricWaveScatterLitAmount: params.scatterLitAmount,
  );
}
