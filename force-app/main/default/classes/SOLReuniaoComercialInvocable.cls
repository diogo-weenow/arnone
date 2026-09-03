/**
 * CLICKUP-9401 — Entrada da criação automática da tarefa de reunião comercial.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Tarefa_Reuniao_Comercial
 * (after-save em Lead) e SOLReuniaoComercialService.criarTarefaReuniao. NÃO
 * duplica lógica, não faz SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO: se a tarefa não puder ser criada (inclusive
 * calendário ausente), a exceção controlada é RELANÇADA para o Flow, abortando
 * a transação inteira — a própria mudança de etapa é desfeita. O vendedor
 * recebe a mensagem controlada. Detalhe técnico só no log de debug.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLReuniaoComercialInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead'
      description='Lead que entrou em "Reunião Agendada - SQL".'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Criar tarefa de reunião comercial SOL'
    description='Consolida os Ids recebidos e chama SOLReuniaoComercialService.criarTarefaReuniao uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void criar(List<Entrada> entradas) {
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
      SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>(ids));
    } catch (SOLReuniaoComercialService.ReuniaoComercialException e) {
      System.debug(LoggingLevel.ERROR, 'SOLReuniaoComercialInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLReuniaoComercialInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLReuniaoComercialService.ReuniaoComercialException(
        SOLReuniaoComercialService.MSG_FALHA
      );
    }
  }
}
