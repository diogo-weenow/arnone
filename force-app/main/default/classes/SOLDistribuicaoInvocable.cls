/**
 * CLICKUP-9394 — Entrada em tempo real do round-robin SOL (ETAPA 5.1).
 *
 * Adaptador fino entre o Record-Triggered Flow SOL_Distribuir_Lead e o serviço
 * SOLDistribuicaoService. NÃO duplica lógica de distribuição, não faz SOQL nem
 * DML, e nunca propaga exceção para o Flow — a criação/atualização do Lead não
 * pode falhar por causa da distribuição. Erro e fallback são responsabilidade
 * do serviço.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLDistribuicaoInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead'
      description='Lead a considerar para a distribuição SOL.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Distribuir Leads SOL (round-robin)'
    description='Consolida os Ids recebidos e chama SOLDistribuicaoService.distribuir uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void distribuir(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    // Consolida os Ids do lote — sem SOQL/DML no laço.
    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (entrada != null && entrada.leadId != null) {
        ids.add(entrada.leadId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      // Uma única chamada por execução bulk.
      SOLDistribuicaoService.distribuir(new List<Id>(ids));
    } catch (Exception e) {
      // Blindagem: nem uma exceção inesperada do serviço pode impedir a
      // gravação do Lead. Detalhe técnico fica só no log de debug.
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
    }
  }
}