/**
 * CLICKUP-9417 — Entrada da sinalização de contato efetivado + cancelamento das
 * tarefas de contato pendentes.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Contato_Efetivado (after-save em
 * Task) e SOLDistribuicaoService.registrarContatoEfetivado. NÃO duplica lógica,
 * não faz SOQL nem DML e nunca propaga exceção para o Flow — concluir a tarefa
 * de contato não pode falhar por causa do cancelamento das demais.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLContatoEfetivadoInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead (WhoId da Task)'
      description='Lead cujo contato foi efetivado.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Registrar contato efetivado SOL (cancela tarefas pendentes)'
    description='Consolida os Ids recebidos e chama SOLDistribuicaoService.registrarContatoEfetivado uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void registrar(List<Entrada> entradas) {
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
      SOLDistribuicaoService.registrarContatoEfetivado(new List<Id>(ids));
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLContatoEfetivadoInvocable: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
    }
  }
}
