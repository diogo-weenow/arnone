trigger LeadTrigger on Lead(before insert, before update) {
  STE_NormalizarTelefone.aplicar(Trigger.new);
}