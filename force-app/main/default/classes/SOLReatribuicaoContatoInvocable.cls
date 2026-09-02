/**
 * CLICKUP-9400 — Entrada da reatribuição de Leads SOL por falta de contato.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Reatribuir_Por_Falta_Contato
 * (after-save em Task) e SOLDistribuicaoService.reatribuirPorFaltaDeContato.
 * NÃO duplica lógica de contagem/rotação, não faz SOQL nem DML e nunca propaga
 * exceção para o Flow — concluir a Task não pode falhar por causa da
 * reatribuição.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLReatribuicaoContatoInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead (WhoId da Task)'
      description='Lead cujo ciclo de contato deve ser avaliado para reatribuição.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Reatribuir Leads SOL por falta de contato'
    description='Consolida os Ids recebidos e chama SOLDistribuicaoService.reatribuirPorFaltaDeContato uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void reatribuir(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (
        entrada != null &&
        entrada.leadId != null &&
        entrada.leadId.getSObjectType() == Lead.SObjectType
      ) {
        ids.add(entrada.leadId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>(ids));
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLReatribuicaoContatoInvocable: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
    }
  }
}
