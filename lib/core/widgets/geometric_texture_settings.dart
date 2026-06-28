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
