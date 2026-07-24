import Foundation

/// Severidade de um sinal do painel de integridade — as três cores do plano §12.3 (verde/laranja/vermelho).
enum HealthSeverity: Sendable, Equatable { case ok, warning, critical }

/// Nível de operação REAL do motor automático — a "degradação honesta" (plano §3.4/§9.10, spec §8). É a
/// peça central deste slice: o iOS NÃO garante o que o Android garante, então o painel nunca promete —
/// ele reporta em qual dos três regimes o motor está, dado o estado de permissões.
enum AutomationHealthLevel: Sendable, Equatable {
    case blocked             // mínimo D5 (notif + precisa) NÃO concedido → o motor não inicia
    case degradedForeground  // mínimo OK, mas background comprometido (sem "Always" ou sem Atualização em 2º Plano) → só foreground
    case operational         // mínimo + "Always" + Atualização em 2º Plano → confiável em background
}

extension PermissionsStatus {
    /// Deriva o nível de saúde SÓ das permissões (independe do toggle de automático — o painel mostra o
    /// toggle numa linha separada). D5: mínimo = notificações + localização precisa. Background confiável
    /// exige **"Always"** (region monitoring/significant-change exigem, spec §1/D5) **e** Atualização em 2º
    /// Plano disponível. Low Power NÃO rebaixa o nível (recomendado, não bloqueante — vira só um aviso).
    var automationHealthLevel: AutomationHealthLevel {
        guard ladder.minimumToStartGranted else { return .blocked }
        let backgroundReliable = alwaysLocationGranted && backgroundRefresh == .available
        return backgroundReliable ? .operational : .degradedForeground
    }
}

/// Relatório de integridade — agregação PURA dos sinais que o painel exibe (§4). Não fixa layout/labels/ordem
/// (isso é do slice de UI, que deve espelhar o `AutoActivitiesDialog.kt` do Kotlin — fidelidade de layout); aqui
/// vivem as REGRAS de severidade e o nível geral, auditáveis e testáveis. A coleta assíncrona dos insumos
/// (fila offline, resumo de geofences, prefs) é integração fina; este valor é montado a partir de primitivos.
struct HealthReport: Sendable, Equatable {
    let permissions: PermissionsStatus
    let lgpdConsentGranted: Bool                 // backgroundLocationConsentAt != ""
    let automaticEnabled: Bool                   // UserSettings.automaticActivitiesEnabled (servidor/local)
    let scheduledPauseActive: Bool
    let nextPauseTransition: Date?               // próxima transição de pausa (best-effort)
    let monitoredRegions: Int                    // GeofenceRegionManager.lastSummary.monitored
    let omittedRegions: Int                      // …omitted (cap 20)
    let lastEvaluation: EvaluationEntry?         // EvaluationLog.shared.snapshot().first
    let offlinePendingCount: Int                 // OfflineCheckQueue.size()

    /// Nível geral do motor (só permissões) — a degradação honesta.
    var level: AutomationHealthLevel { permissions.automationHealthLevel }

    // ── Severidade por sinal (as linhas coloridas do painel) ──────────────────

    var locationSeverity: HealthSeverity {
        switch permissions.location {
        case .precise: return .ok
        case .imprecise: return .warning        // precisão reduzida degrada o match
        case .denied: return .critical          // sem localização o motor não roda
        }
    }

    /// Notificações são parte do mínimo D5 → ausência é crítica.
    var notificationsSeverity: HealthSeverity { permissions.notificationsGranted ? .ok : .critical }

    /// "Always" é recomendada (habilita background), não bloqueante → ausência é aviso, não crítico.
    var alwaysLocationSeverity: HealthSeverity { permissions.alwaysLocationGranted ? .ok : .warning }

    var backgroundRefreshSeverity: HealthSeverity {
        permissions.backgroundRefresh == .available ? .ok : .warning
    }

    /// Low Power só reduz confiabilidade (read-only, sem isenção) → aviso quando ligado.
    var lowPowerSeverity: HealthSeverity { permissions.lowPowerMode ? .warning : .ok }

    /// Consentimento LGPD é pré-condição para localização em background → ausência é crítica.
    var consentSeverity: HealthSeverity { lgpdConsentGranted ? .ok : .critical }

    /// Regiões omitidas pelo cap de 20 — nunca silencioso (plano §9.2).
    var omittedRegionsSeverity: HealthSeverity { omittedRegions > 0 ? .warning : .ok }

    /// Fila offline pendente — aviso enquanto houver eventos não sincronizados.
    var offlineQueueSeverity: HealthSeverity { offlinePendingCount > 0 ? .warning : .ok }

    /// Verdadeiro quando algum estado só é resolvível em **Ajustes** (o iOS não deep-linka por permissão):
    /// negado/restrito não pode ser re-pedido in-app. `notDetermined` e o upgrade When In Use→Always são
    /// resolvíveis por prompt in-app (fluxo da escada), então NÃO forçam Ajustes.
    var needsOpenSettings: Bool {
        let locationNeedsSettings: Bool = {
            switch permissions.locationAuthorization {
            case .denied: return true
            case .notDetermined, .whenInUse, .always: return false
            }
        }()
        // Notificações NEGADAS só se resolvem em Ajustes (o `requestAuthorization` devolve `false` sem UI
        // depois de negado); `notDetermined` ainda é pedível in-app pela escada.
        let notificationsNeedSettings = permissions.notificationAuthorization == .denied
        // `.restricted` é imposto pelo sistema (ex.: controle parental) e, segundo a API do UIKit,
        // não é corrigível pelo usuário. Só `.denied` deve oferecer Ajustes como remédio.
        let backgroundRefreshNeedsSettings = permissions.backgroundRefresh == .denied
        return locationNeedsSettings || notificationsNeedSettings || backgroundRefreshNeedsSettings
    }
}
