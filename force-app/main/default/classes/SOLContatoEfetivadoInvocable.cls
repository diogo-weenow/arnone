/**
 * CLICKUP-9417 — Entrada da sinalização de contato efetivado + cancelamento das
 * tarefas de contato pendentes.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Contato_Efetivado (after-save em
 * Task) e SOLDistribuicaoService.registrarContatoEfetivado. NÃO duplica lógica,
 * não faz SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO (ajuste do PR #5): se o cancelamento não puder
 * ser concluído, a exceção controlada é RELANÇADA para o Flow. Isso aborta a
 * transação inteira — a própria conclusão da Task é desfeita — em vez de
 * deixar a Task concluída e o Lead/tarefas pendentes sem atualizar. O vendedor
 * recebe a mensagem controlada e conclui a tarefa de novo. Detalhe técnico só
 * no log de debug.
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
    } catch (SOLDistribuicaoService.ContatoEfetivadoException e) {
      // Falha já tratada e com Savepoint desfeito no serviço: relança a
      // mensagem controlada para o Flow abortar a transação inteira.
      System.debug(LoggingLevel.ERROR, 'SOLContatoEfetivadoInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      // Qualquer outra falha inesperada: também aborta a transação, com
      // mensagem controlada (nunca detalhe técnico ao vendedor).
      System.debug(
        LoggingLevel.ERROR,
        'SOLContatoEfetivadoInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLDistribuicaoService.ContatoEfetivadoException(
        SOLDistribuicaoService.MSG_CONTATO_EFETIVADO_FALHA
      );
    }
  }
}
